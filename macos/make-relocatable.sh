#!/usr/bin/env bash
set -euo pipefail

R_HOME="${1:?Usage: make-relocatable.sh <r-home> [r-version]}"
R_HOME="$(cd "${R_HOME}" && pwd)"
R_VERSION="${2:-}"

# Determine the version slot used in the orthogonal R_HOME_DIR= rewrite
# (`Versions/<slot>-<arch>/Resources`). Three tiers in priority order:
#
#   1. Aliases — devel/patched/next: use the alias literally. R_VERSION
#      doesn't carry a numeric branch for these, and trying to derive one
#      means the slot would change across R branch rollovers (4.6→4.7…)
#      from identical input. The literal alias is also free of any
#      collision with numeric `<minor>-<arch>` slots used by CRAN/rig.
#   2. Numeric R_VERSION (4.4.3, 4.6.0, …) — parse major.minor.
#   3. Fallback for direct invocation without R_VERSION — introspect via
#      `bin/R --version`. Use the shell wrapper, NOT `bin/exec/R`: the
#      raw Mach-O errors out with "Fatal error: R home directory is not
#      defined" when called without R_HOME in the environment, leaving
#      the regex with no digits to match. The wrapper sets R_HOME itself.
#
# R_MAJOR/R_MINOR remain set after this block for the Rscript R<4.2
# branch below; for tier 1 they stay empty (devel/patched/next are
# always modern R, and the regex guard there skips the <4.2 branch).
R_MAJOR=""
R_MINOR=""
case "${R_VERSION}" in
  devel|patched|next)
    SLOT_VERSION="${R_VERSION}"
    ;;
  *)
    if [[ "${R_VERSION}" =~ ^[0-9]+\.[0-9]+ ]]; then
      R_MAJOR="${R_VERSION%%.*}"
      R_MINOR="${R_VERSION#*.}"; R_MINOR="${R_MINOR%%.*}"
    else
      R_VER_STRING=$("${R_HOME}/bin/R" --version 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "")
      if [ -z "${R_VER_STRING}" ]; then
        echo "ERROR: Could not determine R version for slot computation" >&2
        echo "       R_VERSION='${R_VERSION}', bin/R --version produced no version digits" >&2
        exit 1
      fi
      R_MAJOR="${R_VER_STRING%%.*}"
      R_MINOR="${R_VER_STRING#*.}"; R_MINOR="${R_MINOR%%.*}"
    fi
    SLOT_VERSION="${R_MAJOR}.${R_MINOR}"
    ;;
esac

echo "=== Making R relocatable in ${R_HOME} ==="

# Detect the hardcoded framework path from bin/R (CRAN .pkg sets R_HOME_DIR
# to e.g. /Library/Frameworks/R.framework/Versions/4.4-arm64/Resources for
# orthogonal installs, or /Library/Frameworks/R.framework/Resources for
# non-orthogonal ones — observed on R 4.4.3 macOS arm64 .pkg).
HARDCODED_PATH="$(grep '^R_HOME_DIR=' "${R_HOME}/bin/R" | head -1 | sed 's/^R_HOME_DIR=//' | tr -d '"' | tr -d "'")"
if [ -z "${HARDCODED_PATH}" ]; then
  echo "ERROR: Could not detect hardcoded path from bin/R" >&2
  exit 1
fi
echo "Detected hardcoded path: ${HARDCODED_PATH}"

# Force the static R_HOME_DIR= line to the orthogonal "Versions/<slot>-<arch>/
# Resources" form regardless of what CRAN shipped. Positron's RInstallation
# constructor classifies an install as orthogonal iff its homepath does NOT
# match /R\.framework\/Resources/ (see extensions/positron-r/src/r-installation.ts),
# and a non-orthogonal install is only usable when it's also the system's
# "current" R — which our portable R isn't. Without this rewrite, Positron
# rejects the install with "Non-orthogonal installation that is also not the
# current version" even after symlinking the canonical path.
#
# Detect arch from the actual Mach-O binary; the build is single-arch so this
# returns one definitive value.
ARCH_DETECTED=$(file -b "${R_HOME}/bin/exec/R" 2>/dev/null | grep -oE 'arm64|x86_64' | head -1)
if [ -z "${ARCH_DETECTED}" ]; then
  echo "ERROR: Could not detect arch from ${R_HOME}/bin/exec/R" >&2
  exit 1
fi
ORTHOGONAL_PATH="/Library/Frameworks/R.framework/Versions/${SLOT_VERSION}-${ARCH_DETECTED}/Resources"
echo "Rewriting static R_HOME_DIR to orthogonal path: ${ORTHOGONAL_PATH}"

# Match the static assignment in either quote style. CRAN's R.sh.in
# template has historically written the value either unquoted (R 4.4
# and earlier on macOS arm64: `R_HOME_DIR=/Library/...`) or quoted
# (R 4.6+: `R_HOME_DIR="/Library/..."`). The lib/lib64 conditional
# fallback lines `R_HOME_DIR="/Library/${libnn}/R"` are indented (so
# the leading-anchor `^` excludes them) and also contain `${`, so the
# `[^$"]*` body class would stop short of the closing quote. The
# runtime override we insert below has the form `R_HOME_DIR="$(...)"`
# — value starts with `$`, not `/`, so it doesn't match either.
sed -i '' -E "s|^R_HOME_DIR=\"?/[^\$\"]*\"?\$|R_HOME_DIR=${ORTHOGONAL_PATH}|" "${R_HOME}/bin/R"

# ── 1. Patch bin/R — dynamic R_HOME derivation ─────────────────────
# Strategy (following r-builds PR #280): preserve the original static
# R_HOME_DIR= line for IDE compatibility (Positron, RStudio parse this
# file as text), but insert a dynamic override before R_HOME assignment.
echo "--- Patching bin/R ---"

# Insert dynamic R_HOME_DIR override IMMEDIATELY AFTER the static
# `R_HOME_DIR=/Library/Frameworks/...` assignment. The static line is
# preserved (Positron's getRHomePathDarwin reads the FIRST line
# containing R_HOME_DIR as text, and that's what we want it to find);
# the runtime override fires next so every subsequent reference in the
# script — including the `if test "${R_HOME}" != "${R_HOME_DIR}"`
# warning check, the R_SHARE_DIR / R_INCLUDE_DIR / R_DOC_DIR
# assignments, and the final exec — sees the actual extracted path.
#
# Inserting the override AFTER the warning check (the previous
# approach) caused R to emit "WARNING: ignoring environment value of
# R_HOME" to stdout when bin/R was invoked with R_HOME already exported
# (e.g., by our bin/Rscript wrapper for R >= 4.2). The warning fired
# because at that point R_HOME_DIR was still the framework path, while
# the Rscript wrapper had set env R_HOME to the actual path. Inserting
# the override earlier eliminates the mismatch.
#
# The address `^R_HOME_DIR="?/` matches the static absolute-path
# assignment in either quote style — `R_HOME_DIR=/Library/...`
# (R 4.4 and earlier) or `R_HOME_DIR="/Library/..."` (R 4.6+). The
# conditional libnn fallback lines `R_HOME_DIR="/Library/${libnn}/R"`
# are indented so the leading-anchor `^` excludes them. Our runtime
# override line has the form `R_HOME_DIR="$(...)"` — no `/` follows
# the `="`, so the `?/` requirement excludes it.
sed -i '' -E '/^R_HOME_DIR="?\//a\
# Override R_HOME_DIR for relocatable installation\
R_HOME_DIR="$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")")/.." \&\& pwd)"
' "${R_HOME}/bin/R"

# Patch R_SHARE_DIR, R_INCLUDE_DIR, R_DOC_DIR to be relative
sed -i '' 's|^R_SHARE_DIR=.*|R_SHARE_DIR="${R_HOME_DIR}/share"|' "${R_HOME}/bin/R"
sed -i '' 's|^R_INCLUDE_DIR=.*|R_INCLUDE_DIR="${R_HOME_DIR}/include"|' "${R_HOME}/bin/R"
sed -i '' 's|^R_DOC_DIR=.*|R_DOC_DIR="${R_HOME_DIR}/doc"|' "${R_HOME}/bin/R"
# Replace any remaining references to the hardcoded path in bin/R, but
# skip lines that start with `R_HOME_DIR=`. Positron's getRHomePathDarwin
# (and RStudio's analogous parser) reads the FIRST line containing
# R_HOME_DIR and uses that string as the R home — so the static
# `R_HOME_DIR=/Library/Frameworks/...` assignment must survive intact for
# IDE discovery to work, even though our runtime override (inserted
# above) is what actually executes. Without this exclusion the line gets
# rewritten to `R_HOME_DIR=${R_HOME}` and Positron rejects the install
# with "Can't find DESCRIPTION for the utils package at ${R_HOME}/...".
sed -i '' "/^R_HOME_DIR=/!s|${HARDCODED_PATH}|\${R_HOME}|g" "${R_HOME}/bin/R"
echo "  bin/R: R_HOME_DIR overridden at runtime (original preserved for IDE compat)"

# ── 2. Set up Rscript — version-aware strategy ───────────────────
echo "--- Setting up bin/Rscript ---"
RSCRIPT_BIN="${R_HOME}/bin/Rscript"

if [[ "${R_MAJOR}" =~ ^[0-9]+$ ]] && [[ "${R_MINOR}" =~ ^[0-9]+$ ]] \
   && (( R_MAJOR < 4 || (R_MAJOR == 4 && R_MINOR < 2) )); then
  # R < 4.2: Rscript binary ignores R_HOME env var and uses compiled-in paths.
  # Replace entirely with a shell script that calls bin/R (r-builds PR #280 approach).
  if [ -f "${RSCRIPT_BIN}" ]; then
    rm -f "${RSCRIPT_BIN}" "${RSCRIPT_BIN}.bin"
  fi
  cat > "${RSCRIPT_BIN}" << 'WRAPPER'
#!/bin/sh
R_HOME="$(cd "$(dirname "$0")/.." && pwd)"
exec "${R_HOME}/bin/R" --slave "$@"
WRAPPER
  chmod +x "${RSCRIPT_BIN}"
  echo "  bin/Rscript: replaced with R --no-echo wrapper (R < 4.2 compat)"
else
  # R >= 4.2: Rscript binary respects R_HOME. Preserve it and wrap.
  if [ -f "${RSCRIPT_BIN}" ] && file "${RSCRIPT_BIN}" | grep -q "Mach-O"; then
    mv "${RSCRIPT_BIN}" "${RSCRIPT_BIN}.bin"
    chmod +x "${RSCRIPT_BIN}.bin"
    echo "  bin/Rscript.bin: preserved original Mach-O binary"
  fi
  cat > "${RSCRIPT_BIN}" << 'WRAPPER'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export RHOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export R_HOME="$RHOME"
exec "$SCRIPT_DIR/Rscript.bin" "$@"
WRAPPER
  chmod +x "${RSCRIPT_BIN}"
  echo "  bin/Rscript: replaced with shell wrapper (sets RHOME before launch)"
fi

# ── 3. Patch etc/Makeconf ───────────────────────────────────────────
echo "--- Patching etc/Makeconf ---"
if [ -f "${R_HOME}/etc/Makeconf" ]; then
  # Replace hardcoded framework path with $(R_HOME)
  sed -i '' "s|${HARDCODED_PATH}|\$(R_HOME)|g" "${R_HOME}/etc/Makeconf"
  # Replace -framework R linking with direct dylib linking
  sed -i '' 's|^LIBR = -F.*-framework R|LIBR = -L"$(R_HOME)/lib" -lR|' "${R_HOME}/etc/Makeconf"
  # Strip remaining -F framework flags
  sed -i '' 's|-F/Library/Frameworks/R.framework/[^ ]*||g' "${R_HOME}/etc/Makeconf"
  echo "  etc/Makeconf: patched (prefix -> \$(R_HOME), framework -> -lR, -F flags stripped)"
fi

# ── 4. Patch etc/Renviron ───────────────────────────────────────────
echo "--- Patching etc/Renviron ---"
if [ -f "${R_HOME}/etc/Renviron" ]; then
  sed -i '' "s|${HARDCODED_PATH}|\${R_HOME}|g" "${R_HOME}/etc/Renviron"
  echo "  etc/Renviron: hardcoded path -> \${R_HOME}"
fi

# ── 5. Patch etc/ldpaths ───────────────────────────────────────────
echo "--- Checking etc/ldpaths ---"
if [ -f "${R_HOME}/etc/ldpaths" ]; then
  if grep -q "${HARDCODED_PATH}" "${R_HOME}/etc/ldpaths"; then
    sed -i '' "s|${HARDCODED_PATH}|\${R_HOME}|g" "${R_HOME}/etc/ldpaths"
    echo "  etc/ldpaths: hardcoded path -> \${R_HOME}"
  else
    echo "  etc/ldpaths: already uses relative paths"
  fi
fi

# ── 6. Patch other shell scripts in bin/ ────────────────────────────
# Skip bin/R itself — Phase 1 already patched it with the correct
# exclusion that preserves the static R_HOME_DIR= line for IDE parsers.
# Without this skip, the unconditional global sed below would re-clobber
# that static line back to `R_HOME_DIR=${R_HOME}` and break Positron's
# discovery (the same DESCRIPTION-not-found rejection the Phase 1 fix
# was meant to prevent).
echo "--- Patching other bin/ scripts ---"
find "${R_HOME}/bin" -type f ! -name "*.bin" ! -name "R" | while read -r f; do
  if file "${f}" | grep -q "text" && grep -q "${HARDCODED_PATH}" "${f}" 2>/dev/null; then
    sed -i '' "s|${HARDCODED_PATH}|\${R_HOME}|g" "${f}"
    echo "  $(basename "${f}"): hardcoded paths replaced"
  fi
done

echo "=== Relocatability patching complete ==="
