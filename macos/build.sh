#!/usr/bin/env bash
set -euo pipefail

# build.sh -- Build a portable, relocatable R for macOS from CRAN .pkg
#
# Extracts the official CRAN R .pkg installer and runs the post-build
# patching pipeline to produce a fully relocatable distribution. No
# Homebrew deps, no configure/make, no gfortran bundling -- the CRAN
# .pkg already includes the gfortran runtime and Tcl/Tk frameworks.

# ── Usage / help ─────────────────────────────────────────────────────
usage() {
  cat <<'EOF'
Usage: build.sh <r_version> <arch> [<output_dir>]

Arguments:
  r_version   Required. e.g. 4.5.0, 4.4.1
  arch        arm64 | x86_64
  output_dir  Directory for output tarball (default: current dir)

Environment:
  CRAN_MIRROR   Base mirror URL (default: https://cloud.r-project.org)

Examples:
  ./build.sh 4.5.0 arm64
  ./build.sh 4.4.1 x86_64 /tmp/out
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

# ── Arguments ────────────────────────────────────────────────────────
R_VERSION="${1:?Usage: build.sh <r_version> <arch> [<output_dir>]}"
ARCH="${2:?Usage: build.sh <r_version> <arch> [<output_dir>]}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR_BASE="${3:-$(pwd)}"
CRAN_MIRROR="${CRAN_MIRROR:-https://cloud.r-project.org}"

# Normalise architecture labels
case "${ARCH}" in
  arm64|aarch64) ARCH="arm64"  ;;
  x86_64)        ARCH="x86_64" ;;
  *) echo "ERROR: unsupported architecture: ${ARCH}" >&2; exit 1 ;;
esac

# Validate R_VERSION before constructing any paths that embed it
if [[ ! "${R_VERSION}" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$|^(devel|patched|next)$ ]]; then
  echo "ERROR: invalid R_VERSION '${R_VERSION}'" >&2
  exit 1
fi

# Construct work paths after validation so R_VERSION is known-safe
WORK_DIR="/tmp/r-build-$$"
WORK_OUTPUT_PARENT="/tmp/r-build-out-$$"
WORK_OUTPUT_DIR="${WORK_OUTPUT_PARENT}/R-${R_VERSION}"
trap 'rm -rf "${WORK_DIR}" "${WORK_OUTPUT_PARENT}"' EXIT

echo "=== Building portable R ${R_VERSION} for macOS ${ARCH} ==="
echo "Output dir: ${OUTPUT_DIR_BASE}"

# ── 1. Resolve the CRAN .pkg download URL ────────────────────────────
# CRAN has changed its URL layout across R versions, and nightly builds
# (devel, patched, next) are hosted on mac.r-project.org, not CRAN mirrors.
#
# Release versions:
#   R >= 4.2    arm64  : bin/macosx/big-sur-arm64/base/R-{ver}-arm64.pkg
#   R >= 4.2    x86_64 : bin/macosx/big-sur-x86_64/base/R-{ver}-x86_64.pkg
#   R 4.1.x    arm64  : bin/macosx/big-sur-arm64/base/R-{ver}.pkg
#   R <= 4.1   x86_64 : bin/macosx/base/R-{ver}.pkg
#
# Nightly builds (mac.r-project.org):
#   devel/patched/next : .pkg and .tar.xz for arm64 and x86_64
#
# Strategy: try the most specific URL first, then fall back.

resolve_pkg_url() {
  local ver="$1" arch="$2" mirror="$3"
  local candidates=()

  # Nightly/development builds live on mac.r-project.org
  case "${ver}" in
    devel|patched|next)
      local mac_base="https://mac.r-project.org"
      if [[ "${arch}" == "arm64" ]]; then
        candidates+=(
          "${mac_base}/big-sur-arm64/last-success/R-devel-arm64.pkg"
          "${mac_base}/big-sur-arm64/last-success/R-devel.pkg"
        )
        # Also try versioned branch patterns
        for branch in "4.7" "4.6" "4.5"; do
          candidates+=(
            "${mac_base}/big-sur-arm64/last-success/R-${branch}-branch-arm64.pkg"
          )
        done
      else
        candidates+=(
          "${mac_base}/big-sur-x86_64/last-success/R-devel-x86_64.pkg"
          "${mac_base}/big-sur-x86_64/last-success/R-devel.pkg"
        )
        for branch in "4.7" "4.6" "4.5"; do
          candidates+=(
            "${mac_base}/big-sur-x86_64/last-success/R-${branch}-branch-x86_64.pkg"
          )
        done
      fi
      ;;
    *)
      # Release versions on CRAN mirrors
      local major minor
      major="${ver%%.*}"
      minor="${ver#*.}"; minor="${minor%%.*}"

      if [[ "${arch}" == "arm64" ]]; then
        if (( major < 4 || (major == 4 && minor < 1) )); then
          echo "ERROR: no arm64 CRAN .pkg available for R ${ver}" >&2
          return 1
        fi
        candidates+=(
          "${mirror}/bin/macosx/big-sur-arm64/base/R-${ver}-arm64.pkg"
          "${mirror}/bin/macosx/big-sur-arm64/base/R-${ver}.pkg"
        )
      else
        candidates+=(
          "${mirror}/bin/macosx/big-sur-x86_64/base/R-${ver}-x86_64.pkg"
          "${mirror}/bin/macosx/big-sur-x86_64/base/R-${ver}.pkg"
          "${mirror}/bin/macosx/base/R-${ver}.pkg"
        )
      fi
      ;;
  esac

  for url in "${candidates[@]}"; do
    if curl -sfI --retry 2 --connect-timeout 10 "${url}" >/dev/null 2>&1; then
      echo "${url}"
      return 0
    fi
  done

  echo "ERROR: could not resolve .pkg URL for R ${ver} (${arch})" >&2
  echo "Tried:" >&2
  printf '  %s\n' "${candidates[@]}" >&2
  return 1
}

echo "--- Resolving CRAN download URL ---"
DOWNLOAD_URL="$(resolve_pkg_url "${R_VERSION}" "${ARCH}" "${CRAN_MIRROR}")"
PKG_FILE="$(basename "${DOWNLOAD_URL}")"
echo "URL: ${DOWNLOAD_URL}"

# ── 2. Download the .pkg ─────────────────────────────────────────────
echo "--- Downloading R ${R_VERSION} .pkg ---"
mkdir -p "${WORK_DIR}"

curl -fSL --retry 3 -o "${WORK_DIR}/${PKG_FILE}" "${DOWNLOAD_URL}"
echo "  Downloaded ${PKG_FILE}"

# ── 3. Extract .pkg without installing ───────────────────────────────
echo "--- Extracting .pkg with pkgutil --expand-full ---"
EXPAND_DIR="${WORK_DIR}/expanded"
rm -rf "${EXPAND_DIR}"
pkgutil --expand-full "${WORK_DIR}/${PKG_FILE}" "${EXPAND_DIR}"

# Locate R.framework inside the expanded payload; assert exactly one match.
R_FRAMEWORK_CANDIDATES="$(find "${EXPAND_DIR}" -type d -name "R.framework" 2>/dev/null)"
R_FRAMEWORK_COUNT="$(echo "${R_FRAMEWORK_CANDIDATES}" | grep -c . 2>/dev/null || echo 0)"
if [[ "${R_FRAMEWORK_COUNT}" -ne 1 ]]; then
  echo "ERROR: expected exactly 1 R.framework directory, found ${R_FRAMEWORK_COUNT}" >&2
  find "${EXPAND_DIR}" -maxdepth 4 -type d >&2
  exit 1
fi
R_FRAMEWORK="${R_FRAMEWORK_CANDIDATES}"
echo "  Found: ${R_FRAMEWORK}"

# ── 4. Flatten R.framework into output directory ─────────────────────
# R.framework/Versions/{ver}-{arch}/Resources holds the actual R tree.
# The version directory name varies (e.g. "4.4-arm64", "4.3-x86_64",
# "4.4", or accessed via the "Current" symlink).
echo "--- Flattening R.framework layout ---"

R_MAJOR="${R_VERSION%%.*}"
R_MINOR="${R_VERSION#*.}"; R_MINOR="${R_MINOR%%.*}"

mkdir -p "${WORK_OUTPUT_PARENT}"

R_RESOURCES=""
for candidate in \
  "${R_FRAMEWORK}/Versions/Current/Resources" \
  "${R_FRAMEWORK}/Versions/${R_MAJOR}.${R_MINOR}-${ARCH}/Resources" \
  "${R_FRAMEWORK}/Versions/${R_MAJOR}.${R_MINOR}/Resources" \
; do
  if [[ -d "${candidate}" ]]; then
    R_RESOURCES="${candidate}"
    break
  fi
done

# Last resort: search
if [[ -z "${R_RESOURCES}" ]]; then
  R_RESOURCES="$(find "${R_FRAMEWORK}/Versions" -maxdepth 2 -type d -name Resources | head -1)"
fi

if [[ -z "${R_RESOURCES}" || ! -d "${R_RESOURCES}" ]]; then
  echo "ERROR: could not locate Resources inside R.framework" >&2
  find "${R_FRAMEWORK}" -maxdepth 4 -type d >&2
  exit 1
fi
echo "  Resources: ${R_RESOURCES}"

rm -rf "${WORK_OUTPUT_DIR}"
cp -R "${R_RESOURCES}" "${WORK_OUTPUT_DIR}"
echo "  Copied to ${WORK_OUTPUT_DIR}"

# ── 4b. Extract Tcl/Tk from sub-package (older .pkg bundles it separately) ──
# R >= 4.3 bundles Tcl/Tk inside R.framework. Older .pkg files ship it as a
# separate tcltk*.pkg that installs to /usr/local/lib or /opt/R/{arch}/lib.
# We extract it and bundle into our lib/ and share/ directories.
TCLTK_PKG="$(find "${EXPAND_DIR}" -maxdepth 1 -type d -name "tcltk*" | head -1)"
if [[ -n "${TCLTK_PKG}" && -d "${TCLTK_PKG}/Payload" ]]; then
  echo "--- Extracting Tcl/Tk from sub-package ---"
  TCLTK_PAYLOAD="${TCLTK_PKG}/Payload"

  # Find the lib directory containing libtcl*.dylib. head -1 is intentional:
  # multiple versioned libtcl*.dylib variants can coexist and we only need
  # any one of them to locate the containing lib directory.
  TCLTK_LIB="$(find "${TCLTK_PAYLOAD}" -name "libtcl*.dylib" -type f -print -quit 2>/dev/null)"
  if [[ -n "${TCLTK_LIB}" ]]; then
    TCLTK_LIB_DIR="$(dirname "${TCLTK_LIB}")"
    echo "  Found Tcl/Tk libs in: ${TCLTK_LIB_DIR}"

    # Copy dylibs to our lib/ directory
    for dylib in "${TCLTK_LIB_DIR}"/libtcl*.dylib "${TCLTK_LIB_DIR}"/libtk*.dylib; do
      if [[ -f "${dylib}" ]]; then
        cp -v "${dylib}" "${WORK_OUTPUT_DIR}/lib/"
      fi
    done

    # Copy Tcl/Tk script directories (tcl8.6/, tk8.6/) for init.tcl etc.
    for tcldir in "tcl8.6" "tk8.6" "tcl8" "tcl8.5" "tk8.5"; do
      if [[ -d "${TCLTK_LIB_DIR}/${tcldir}" ]]; then
        mkdir -p "${WORK_OUTPUT_DIR}/lib/${tcldir}"
        cp -R "${TCLTK_LIB_DIR}/${tcldir}/" "${WORK_OUTPUT_DIR}/lib/${tcldir}/"
        echo "  Copied ${tcldir} scripts to lib/${tcldir}"
      fi
    done
    echo "  Tcl/Tk libraries bundled"
  else
    echo "  tcltk sub-package found but no libtcl dylib inside (may be framework-bundled)"
  fi
else
  echo "--- No tcltk sub-package found (Tcl/Tk likely bundled in R.framework) ---"
fi

# ── 5. Run post-build patching pipeline ──────────────────────────────
# The CRAN .pkg hardcodes /Library/Frameworks/R.framework/... throughout
# its Mach-O binaries and config files. Our existing pipeline handles
# all of this:
#   patch-mach-o.sh      - rewrites dylib load commands to @rpath / @loader_path
#   make-relocatable.sh  - patches bin/R, bin/Rscript, etc/Makeconf, etc/Renviron
#   install-rprofile-hook.sh - installs Rprofile.site with .portable env
echo "--- Running post-build patching pipeline ---"

bash "${SCRIPT_DIR}/patch-mach-o.sh"          "${WORK_OUTPUT_DIR}"
bash "${SCRIPT_DIR}/make-relocatable.sh"       "${WORK_OUTPUT_DIR}" "${R_VERSION}"
bash "${SCRIPT_DIR}/install-rprofile-hook.sh"  "${WORK_OUTPUT_DIR}"

# ── 6. Package tarball ───────────────────────────────────────────────
echo "--- Packaging tarball ---"
mkdir -p "${OUTPUT_DIR_BASE}"
TARBALL="${OUTPUT_DIR_BASE}/R-${R_VERSION}-macos-${ARCH}.tar.gz"
tar czf "${TARBALL}" -C "${WORK_OUTPUT_PARENT}" "R-${R_VERSION}"
echo "=== Tarball created: ${TARBALL} ==="

# ── Cleanup ──────────────────────────────────────────────────────────
# Cleanup is handled by the EXIT trap set at the top of the script.
echo "=== Build complete ==="
