#!/usr/bin/env bash
set -euo pipefail

R_HOME="${1:?Usage: patch-mach-o.sh <r-home>}"
R_HOME="$(cd "${R_HOME}" && pwd)"

echo "=== Patching Mach-O binaries in ${R_HOME} ==="

# Detect the hardcoded framework path from the CRAN .pkg extraction.
# CRAN binaries embed paths like /Library/Frameworks/R.framework/Versions/4.4-arm64/Resources/...
# We match any reference containing /Library/Frameworks/R.framework.
FRAMEWORK_PATTERN="/Library/Frameworks/R.framework"

echo "Patching references matching: ${FRAMEWORK_PATTERN}"

# Non-system absolute paths that may appear in CRAN .pkg binaries.
# /opt/R/{arch}/lib — R 4.3+ Tcl/Tk
# /usr/local/lib — R <= 4.2 Tcl/Tk (x86_64)
# We only rewrite these if the target library exists in our lib/ directory.
NON_SYSTEM_PATTERNS="/opt/R/|/usr/local/(lib|opt|Cellar)/"

patch_non_system_refs() {
  local binary="$1"
  local rpath_prefix="$2"
  otool -L "${binary}" 2>/dev/null | awk 'NR>1{print $1}' | while read -r ref; do
    if echo "${ref}" | grep -qE "${NON_SYSTEM_PATTERNS}"; then
      local lib_name
      lib_name="$(basename "${ref}")"
      if [[ -f "${R_HOME}/lib/${lib_name}" ]]; then
        patch_ref "${binary}" "${ref}" "${rpath_prefix}/${lib_name}"
        echo "  $(basename "${binary}"): ${ref} -> ${rpath_prefix}/${lib_name}"
      fi
    fi
  done
}

patch_id() {
  local dylib="$1"
  local new_id="$2"
  install_name_tool -id "${new_id}" "${dylib}" \
    || echo "  WARNING: failed to set ID on $(basename "${dylib}"): ${new_id}" >&2
  echo "  ID: $(basename "${dylib}") -> ${new_id}"
}

patch_ref() {
  local binary="$1"
  local old_ref="$2"
  local new_ref="$3"
  install_name_tool -change "${old_ref}" "${new_ref}" "${binary}" \
    || echo "  WARNING: failed to patch $(basename "${binary}"): ${old_ref}" >&2
}

add_rpath() {
  local binary="$1"
  local rpath="$2"
  install_name_tool -add_rpath "${rpath}" "${binary}" 2>/dev/null || true
}

# ── 1. Patch lib/*.dylib — set @rpath IDs, @loader_path peer refs ──
echo "--- Patching lib/*.dylib ---"
find "${R_HOME}/lib" -maxdepth 1 -name "*.dylib" -type f 2>/dev/null | while read -r dylib; do
  old_id=$(otool -D "${dylib}" 2>/dev/null | tail -1)
  if echo "${old_id}" | grep -q "${FRAMEWORK_PATTERN}"; then
    patch_id "${dylib}" "@rpath/$(basename "${old_id}")"
  fi

  otool -L "${dylib}" 2>/dev/null | awk 'NR>1{print $1}' | while read -r ref; do
    if echo "${ref}" | grep -q "${FRAMEWORK_PATTERN}"; then
      lib_name="$(basename "${ref}")"
      patch_ref "${dylib}" "${ref}" "@loader_path/${lib_name}"
      echo "  $(basename "${dylib}"): ${lib_name} -> @loader_path/${lib_name}"
    fi
  done
done

# Also patch non-system refs in dylibs (e.g. libtcl/libtk cross-references)
find "${R_HOME}/lib" -maxdepth 1 -name "*.dylib" -type f 2>/dev/null | while read -r dylib; do
  patch_non_system_refs "${dylib}" "@loader_path"
done

# Patch IDs and cross-refs of bundled Tcl/Tk dylibs (may reference /opt/R or /usr/local)
find "${R_HOME}/lib" -maxdepth 1 -name "*.dylib" -type f 2>/dev/null | while read -r dylib; do
  old_id=$(otool -D "${dylib}" 2>/dev/null | tail -1)
  if echo "${old_id}" | grep -qE "${NON_SYSTEM_PATTERNS}"; then
    patch_id "${dylib}" "@rpath/$(basename "${old_id}")"
  fi
done

# ── 2. Patch bin/exec/R — the main executable ──────────────────────
echo "--- Patching bin/exec/R ---"
R_BIN="${R_HOME}/bin/exec/R"
if [ -f "${R_BIN}" ]; then
  otool -L "${R_BIN}" 2>/dev/null | awk 'NR>1{print $1}' | while read -r ref; do
    if echo "${ref}" | grep -q "${FRAMEWORK_PATTERN}"; then
      lib_name="$(basename "${ref}")"
      patch_ref "${R_BIN}" "${ref}" "@executable_path/../../lib/${lib_name}"
      echo "  bin/exec/R: ${lib_name} -> @executable_path/../../lib/${lib_name}"
    fi
  done
  add_rpath "${R_BIN}" "@executable_path/../../lib"
  echo "  Added LC_RPATH: @executable_path/../../lib"
fi

# ── 3. Patch bin/Rscript (if still a Mach-O binary) ────────────────
echo "--- Patching bin/Rscript ---"
RSCRIPT_BIN="${R_HOME}/bin/Rscript"
# Also check for Rscript.bin (preserved original binary)
for rscript in "${RSCRIPT_BIN}" "${RSCRIPT_BIN}.bin"; do
  if [ -f "${rscript}" ] && file "${rscript}" | grep -q "Mach-O"; then
    otool -L "${rscript}" 2>/dev/null | awk 'NR>1{print $1}' | while read -r ref; do
      if echo "${ref}" | grep -q "${FRAMEWORK_PATTERN}"; then
        lib_name="$(basename "${ref}")"
        patch_ref "${rscript}" "${ref}" "@executable_path/../lib/${lib_name}"
        echo "  $(basename "${rscript}"): ${lib_name} -> @executable_path/../lib/${lib_name}"
      fi
    done
  fi
done

# ── 4. Patch library/*/libs/*.so — base R package extensions ───────
echo "--- Patching library/*/libs/*.so ---"
find "${R_HOME}/library" -name "*.so" -type f 2>/dev/null | while read -r so; do
  otool -L "${so}" 2>/dev/null | awk 'NR>1{print $1}' | while read -r ref; do
    if echo "${ref}" | grep -q "${FRAMEWORK_PATTERN}"; then
      lib_name="$(basename "${ref}")"
      patch_ref "${so}" "${ref}" "@rpath/${lib_name}"
    fi
  done
  patch_non_system_refs "${so}" "@rpath"
  add_rpath "${so}" "@loader_path/../../../lib"
done
echo "  Patched library .so files with @rpath refs + LC_RPATH @loader_path/../../../lib"

# ── 5. Patch modules/*.so — R internal modules ─────────────────────
echo "--- Patching modules/*.so ---"
find "${R_HOME}/modules" -name "*.so" -type f 2>/dev/null | while read -r so; do
  otool -L "${so}" 2>/dev/null | awk 'NR>1{print $1}' | while read -r ref; do
    if echo "${ref}" | grep -q "${FRAMEWORK_PATTERN}"; then
      lib_name="$(basename "${ref}")"
      patch_ref "${so}" "${ref}" "@rpath/${lib_name}"
    fi
  done
  patch_non_system_refs "${so}" "@rpath"
  add_rpath "${so}" "@loader_path/../lib"
done
echo "  Patched module .so files with @rpath refs + LC_RPATH @loader_path/../lib"

# ── 6. Codesign all Mach-O binaries ────────────────────────────────
# If CODESIGN_IDENTITY is set, sign with Developer ID + hardened runtime
# + entitlements (required for notarization). Otherwise, fall back to
# ad-hoc signing for local development.

SIGN_ID="${CODESIGN_IDENTITY:--}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENTITLEMENTS="${SCRIPT_DIR}/entitlements.plist"

if [ "${SIGN_ID}" != "-" ]; then
  echo "--- Codesigning with Developer ID (hardened runtime) ---"
  echo "  Identity: ${SIGN_ID}"

  if [ ! -f "${ENTITLEMENTS}" ]; then
    echo "ERROR: entitlements.plist not found at ${ENTITLEMENTS}" >&2
    exit 1
  fi

  # Libraries first (innermost), then executables (outermost).
  # Libraries are signed without entitlements; executables get entitlements.
  CODESIGN_LIB=(codesign --force --sign "${SIGN_ID}" --timestamp --options runtime)
  CODESIGN_EXE=(codesign --force --sign "${SIGN_ID}" --timestamp --options runtime --entitlements "${ENTITLEMENTS}")

  # Sign dylibs (fail on error — broken signing means broken notarization)
  find "${R_HOME}" -type f -name '*.dylib' -exec "${CODESIGN_LIB[@]}" {} \;

  # Sign .so files (bundled packages + modules)
  find "${R_HOME}" -type f -name '*.so' -exec "${CODESIGN_LIB[@]}" {} \;

  # Sign executables with entitlements
  [ -f "${R_BIN}" ] && "${CODESIGN_EXE[@]}" "${R_BIN}"
  for rscript in "${RSCRIPT_BIN}" "${RSCRIPT_BIN}.bin"; do
    if [ -f "${rscript}" ] && file "${rscript}" | grep -q "Mach-O"; then
      "${CODESIGN_EXE[@]}" "${rscript}"
    fi
  done

  # Catch-all: sign any remaining unsigned Mach-O files
  find "${R_HOME}" -type f | while read -r f; do
    if file "${f}" 2>/dev/null | grep -q "Mach-O"; then
      codesign --verify "${f}" 2>/dev/null || "${CODESIGN_LIB[@]}" "${f}"
    fi
  done

  echo "  Signed all binaries with hardened runtime"
else
  echo "--- Ad-hoc codesigning ---"
  find "${R_HOME}" -type f \( -name '*.dylib' -o -name '*.so' \) -exec codesign -f -s - {} \; 2>/dev/null
  [ -f "${R_BIN}" ] && codesign -f -s - "${R_BIN}" 2>/dev/null
  for rscript in "${RSCRIPT_BIN}" "${RSCRIPT_BIN}.bin"; do
    if [ -f "${rscript}" ] && file "${rscript}" | grep -q "Mach-O"; then
      codesign -f -s - "${rscript}" 2>/dev/null
    fi
  done
  echo "  Ad-hoc signed all Mach-O binaries"
fi

echo "=== Mach-O patching complete ==="
