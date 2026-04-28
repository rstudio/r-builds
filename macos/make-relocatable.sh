#!/usr/bin/env bash
set -euo pipefail

R_HOME="${1:?Usage: make-relocatable.sh <r-home> [r-version]}"
R_HOME="$(cd "${R_HOME}" && pwd)"
R_VERSION="${2:-}"

# Parse major.minor for version-specific handling. R_VERSION may be "devel",
# "patched", or "next" — non-numeric — so fall back to introspecting the binary
# in that case (and when R_VERSION is unset entirely).
if [[ -n "${R_VERSION}" ]] && [[ "${R_VERSION}" =~ ^[0-9]+\.[0-9]+ ]]; then
  R_MAJOR="${R_VERSION%%.*}"
  R_MINOR="${R_VERSION#*.}"; R_MINOR="${R_MINOR%%.*}"
else
  R_VER_STRING=$("${R_HOME}/bin/exec/R" --version 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "")
  R_MAJOR="${R_VER_STRING%%.*}"
  R_MINOR="${R_VER_STRING#*.}"; R_MINOR="${R_MINOR%%.*}"
fi

echo "=== Making R relocatable in ${R_HOME} ==="

# Detect the hardcoded framework path from bin/R (CRAN .pkg sets R_HOME_DIR
# to e.g. /Library/Frameworks/R.framework/Versions/4.4-arm64/Resources).
HARDCODED_PATH="$(grep '^R_HOME_DIR=' "${R_HOME}/bin/R" | head -1 | sed 's/^R_HOME_DIR=//' | tr -d '"' | tr -d "'")"
if [ -z "${HARDCODED_PATH}" ]; then
  echo "ERROR: Could not detect hardcoded path from bin/R" >&2
  exit 1
fi
echo "Detected hardcoded path: ${HARDCODED_PATH}"

# ── 1. Patch bin/R — dynamic R_HOME derivation ─────────────────────
# Strategy (following r-builds PR #280): preserve the original static
# R_HOME_DIR= line for IDE compatibility (Positron, RStudio parse this
# file as text), but insert a dynamic override before R_HOME assignment.
echo "--- Patching bin/R ---"

# Insert dynamic R_HOME_DIR override before the R_HOME assignment line.
# This preserves the original static R_HOME_DIR= for IDE parsers while
# ensuring runtime behavior derives the path dynamically.
sed -i '' '/^R_HOME="${R_HOME_DIR}"$/i\
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
echo "--- Patching other bin/ scripts ---"
find "${R_HOME}/bin" -type f ! -name "*.bin" | while read -r f; do
  if file "${f}" | grep -q "text" && grep -q "${HARDCODED_PATH}" "${f}" 2>/dev/null; then
    sed -i '' "s|${HARDCODED_PATH}|\${R_HOME}|g" "${f}"
    echo "  $(basename "${f}"): hardcoded paths replaced"
  fi
done

echo "=== Relocatability patching complete ==="
