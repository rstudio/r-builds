#!/usr/bin/env bash
# Make an R installation relocatable by patching bin/R and bin/Rscript
# to detect their own location at runtime via readlink -f.
#
# Usage: make-relocatable.sh <R_INSTALL_PATH>
#
# This can be reused across all r-builds platforms (manylinux, musllinux,
# and standard distro-specific builds).
set -ex

R_INSTALL_PATH="${1:?Usage: make-relocatable.sh <R_INSTALL_PATH>}"

echo ">>> Make bin/R relocatable"
# The installed bin/R script has R_HOME_DIR hardcoded to the build-time prefix.
# We add a dynamic override that derives R_HOME from the script's own location
# via readlink -f, making R relocatable.
#
# This works across all R versions (3.0 through 4.5+) because the R_HOME_DIR
# assignment has been structurally stable in R.sh.in since R 2.x.
#
# We keep the original static R_HOME_DIR assignment and the lib/lib64 `if test`
# block intact. Tools like Positron parse bin/R as text to discover R_HOME_DIR,
# and they expect the standard R script structure with both lines. By appending
# the dynamic override after the `fi`, parsers see the static path they expect,
# while the override takes effect at runtime.
#
# Two scripts need patching with DIFFERENT formulas:
#   bin/R        -> dirname(dirname(readlink -f $0))/lib/R   (script is at <prefix>/bin/R)
#   lib/R/bin/R  -> dirname(dirname(readlink -f $0))         (script is at <R_HOME>/bin/R)
# R CMD INSTALL and other subprocesses invoke lib/R/bin/R directly, so both must work.
sed -i '/^R_HOME_DIR=/,/^fi$/{
  /^fi$/a\
# Override R_HOME_DIR for relocatable installation\
R_HOME_DIR="$(dirname "$(dirname "$(readlink -f "$0")")")/lib/R"
}' "${R_INSTALL_PATH}/bin/R"

# Fix R_SHARE_DIR, R_INCLUDE_DIR, R_DOC_DIR -- these are hardcoded to the
# build-time prefix by configure. Replace them with ${R_HOME}-relative paths.
for r_script in "${R_INSTALL_PATH}/bin/R" "${R_INSTALL_PATH}/lib/R/bin/R"; do
  [ -f "$r_script" ] || continue
  sed -i 's|^R_SHARE_DIR=.*|R_SHARE_DIR=${R_HOME}/share|' "$r_script"
  sed -i 's|^R_INCLUDE_DIR=.*|R_INCLUDE_DIR=${R_HOME}/include|' "$r_script"
  sed -i 's|^R_DOC_DIR=.*|R_DOC_DIR=${R_HOME}/doc|' "$r_script"
done

# Patch lib/R/bin/R (the copy inside R_HOME, invoked by R CMD INSTALL etc.)
# Only patch if it's a regular file (not a symlink to bin/R).
R_HOME_BIN_R="${R_INSTALL_PATH}/lib/R/bin/R"
if [ -f "${R_HOME_BIN_R}" ] && [ ! -L "${R_HOME_BIN_R}" ]; then
  sed -i '/^R_HOME_DIR=/,/^fi$/{
    /^fi$/a\
# Override R_HOME_DIR for relocatable installation\
R_HOME_DIR="$(dirname "$(dirname "$(readlink -f "$0")")")"
  }' "${R_HOME_BIN_R}"
  echo "  Patched lib/R/bin/R"
fi

echo ">>> Replace Rscript with relocatable wrapper"
# Replace compiled Rscript binary with a relocatable shell wrapper.
# The compiled Rscript has R_HOME hardcoded at compile time and doesn't check
# the R_HOME env var, so it can't find bin/R after relocation.
# The wrapper replicates Rscript's argument handling: options like --verbose,
# --default-packages are processed; -e expressions pass through; the first
# positional arg becomes --file=arg; remaining positional args use --args.
for rscript in "${R_INSTALL_PATH}/bin/Rscript" "${R_INSTALL_PATH}/lib/R/bin/Rscript"; do
  [ -f "$rscript" ] || continue
  # Determine R_HOME formula based on location (same logic as bin/R vs lib/R/bin/R)
  if [[ "$rscript" == */lib/R/bin/Rscript ]]; then
    r_home_formula='R_HOME="$(dirname "$(dirname "$(readlink -f "$0")")")"'
  else
    r_home_formula='R_HOME="$(dirname "$(dirname "$(readlink -f "$0")")")/lib/R"'
  fi
  cat > "$rscript" <<'RSCRIPT_OUTER'
#!/bin/sh
# Relocatable Rscript wrapper (replaces compiled binary for portability)
RSCRIPT_OUTER
  echo "${r_home_formula}" >> "$rscript"
  cat >> "$rscript" <<'RSCRIPT_EOF'
export R_HOME

# Process Rscript-specific options, collect pass-through R options.
# R understands --verbose, --vanilla, --no-environ, --no-site-file, etc.
# directly, so we only need to handle --default-packages (env var conversion)
# and file argument conversion (first positional arg -> --file=).
r_opts=""
while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h)
      echo "Usage: Rscript [options] [-e expr [-e expr2 ...] | file] [args]"
      exit 0
      ;;
    --version)
      exec "${R_HOME}/bin/R" --slave -e 'cat(sprintf("Rscript (R) version %s.%s (%s)\n", R.version$major, R.version$minor, R.version$date))'
      ;;
    --default-packages=*)
      R_DEFAULT_PACKAGES="${1#--default-packages=}"
      export R_DEFAULT_PACKAGES
      shift
      ;;
    -e)
      # -e starts expressions -- stop processing options, pass rest to R
      break
      ;;
    --*)
      # Collect R options (--verbose, --vanilla, --no-environ, etc.)
      r_opts="$r_opts $1"
      shift
      ;;
    *)
      # First positional arg is the script file
      break
      ;;
  esac
done

# $@ now contains: [-e expr ...] or [file [args...]] or nothing
# r_opts contains collected --options (no spaces in individual options)
if [ $# -eq 0 ]; then
  # No file or -e: just R options
  exec "${R_HOME}/bin/R" --slave --no-restore $r_opts
elif [ "$1" = "-e" ]; then
  # -e expressions: pass through directly (preserves quoting via "$@")
  exec "${R_HOME}/bin/R" --slave --no-restore $r_opts "$@"
else
  # File argument: convert to --file=, remaining args become --args
  file="$1"
  shift
  if [ $# -gt 0 ]; then
    exec "${R_HOME}/bin/R" --slave --no-restore $r_opts "--file=$file" --args "$@"
  else
    exec "${R_HOME}/bin/R" --slave --no-restore $r_opts "--file=$file"
  fi
fi
RSCRIPT_EOF
  chmod +x "$rscript"
  echo "  Replaced $(basename "$(dirname "$rscript")")/Rscript with relocatable wrapper"
done
