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

echo ">>> Make Rscript relocatable (preserve binary, wrap with RHOME)"
# The compiled Rscript binary has R_HOME baked in at compile time, so after
# relocation it would exec the wrong (build-time) bin/R.
#
# But Rscript reads the RHOME environment variable and, when set, execs
# "${RHOME}/bin/R" instead of the compiled-in path. This has held for every R
# version we support (3.0+). See getenv("RHOME") in R's src/unix/Rscript.c:
# https://github.com/wch/r-source/blob/tags/R-4-6-0/src/unix/Rscript.c#L230-L280
#
# So we preserve the original binary as Rscript.bin and install a thin wrapper
# that sets RHOME from its own location and execs the real binary.
#
# Rscript depends only on libc + ld (no bundled libs), so the preserved binary
# needs no RPATH/patchelf handling.
for rscript in "${R_INSTALL_PATH}/bin/Rscript" "${R_INSTALL_PATH}/lib/R/bin/Rscript"; do
  [ -f "$rscript" ] || continue
  # RHOME must be R_HOME (<prefix>/lib/R). Formula depends on the script's depth,
  # same logic as the bin/R vs lib/R/bin/R distinction above.
  #   bin/Rscript        is at <prefix>/bin/Rscript        -> RHOME=<prefix>/lib/R
  #   lib/R/bin/Rscript  is at <R_HOME>/bin/Rscript        -> RHOME=<R_HOME>
  if [[ "$rscript" == */lib/R/bin/Rscript ]]; then
    rhome_formula='RHOME="$(dirname "$(dirname "$(readlink -f "$0")")")"'
  else
    rhome_formula='RHOME="$(dirname "$(dirname "$(readlink -f "$0")")")/lib/R"'
  fi
  mv "$rscript" "${rscript}.bin"
  cat > "$rscript" <<'RSCRIPT_HEAD'
#!/bin/sh
# Relocatable Rscript wrapper: set RHOME from our own location, then exec the
# preserved native binary, which reads RHOME and execs "${RHOME}/bin/R".
RSCRIPT_HEAD
  echo "${rhome_formula}" >> "$rscript"
  cat >> "$rscript" <<'RSCRIPT_TAIL'
export RHOME
exec "$(dirname "$(readlink -f "$0")")/Rscript.bin" "$@"
RSCRIPT_TAIL
  chmod +x "$rscript"
  echo "  Wrapped $(basename "$(dirname "$rscript")")/Rscript (preserved as Rscript.bin)"
done
