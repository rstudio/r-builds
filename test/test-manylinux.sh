#!/usr/bin/env bash
set -ex

# Test script for manylinux_2_28 portable R builds.
# Runs on various distros to validate cross-distro portability.
#
# Tested distros: Ubuntu Noble, Rocky Linux 8, Rocky Linux 10, openSUSE 15.6
#
# This script:
# 1. Installs R from the tarball (not DEB/RPM)
# 2. Installs distro-appropriate build tools and runtime deps
# 3. Runs the standard test suite (test-r.sh → test.R)
# 4. Runs manylinux-specific tests (relocatability, R CMD INSTALL, SSL)

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

# Install R from the tarball.
TARBALL_DIR="${SCRIPT_DIR}/../builder/integration/tmp/r/${OS_IDENTIFIER}"
TARBALL=$(ls "${TARBALL_DIR}"/R-${R_VERSION}*.tar.gz 2>/dev/null | head -1)

if [ -z "$TARBALL" ]; then
  echo "ERROR: No tarball found for R ${R_VERSION} in ${TARBALL_DIR}"
  ls -la "${TARBALL_DIR}/" 2>/dev/null || echo "  Directory does not exist"
  exit 1
fi

# Install build tools and runtime dependencies.
# These are the manylinux_2_28 allowed libs (not bundled) plus dev tools
# needed for R package compilation.
echo "=== Installing build tools and runtime dependencies ==="
if command -v apt-get &>/dev/null; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y --no-install-recommends \
    build-essential gfortran ca-certificates less tar gzip \
    libpcre2-dev libpcre3-dev liblzma-dev libbz2-dev zlib1g-dev libicu-dev \
    fontconfig tcl tk
elif command -v dnf &>/dev/null; then
  dnf install -y \
    gcc gcc-c++ gcc-gfortran make ca-certificates less which tar gzip \
    pcre2-devel xz-devel bzip2-devel zlib-devel libicu-devel \
    fontconfig
  # pcre-devel (PCRE1) is only needed for R 3.x and may not exist on newer distros
  dnf install -y pcre-devel 2>/dev/null || true
elif command -v zypper &>/dev/null; then
  zypper --non-interactive install \
    gcc gcc-c++ gcc-fortran make ca-certificates less which tar gzip \
    pcre2-devel pcre-devel xz-devel libbz2-devel zlib-devel libicu-devel \
    fontconfig
else
  echo "ERROR: No supported package manager found"
  exit 1
fi
echo "Build tools installation done."

echo "=== Installing R from tarball: ${TARBALL} ==="
mkdir -p /opt/R
tar xzf "${TARBALL}" -C /opt/R

# Run the standard test suite (same as all other platforms).
echo "=== Running standard test suite ==="
"${SCRIPT_DIR}/test-r.sh"

# Manylinux-specific tests below.
R_PREFIX=/opt/R/${R_VERSION}
R_HOME=${R_PREFIX}/lib/R

echo "=== Shared library dependencies (libR.so) ==="
ldd "${R_HOME}/lib/libR.so" || true

echo "=== Shared library dependencies (exec binary) ==="
ldd "${R_HOME}/bin/exec/R" || true

echo "=== RPATH on exec binary ==="
readelf -d "${R_HOME}/bin/exec/R" | grep -i 'rpath\|runpath' || echo "(no RPATH — uses LD_LIBRARY_PATH from ldpaths)"

echo "=== Verify bundled libs exist ==="
LIBS_DIR=$(find "${R_PREFIX}" -name ".libs" -type d | head -1)
if [ -n "$LIBS_DIR" ]; then
  echo "  Bundled libs in ${LIBS_DIR}: $(ls "$LIBS_DIR" | wc -l) files"
else
  echo "WARNING: No .libs directory found — auditwheel-r may not have bundled anything"
fi

echo "=== Verify SSL CA detection ==="
"${R_HOME}/bin/Rscript" -e '
  # CURL_CA_BUNDLE should be set by etc/ldpaths
  ca <- Sys.getenv("CURL_CA_BUNDLE")
  if (nchar(ca) == 0) stop("CURL_CA_BUNDLE is not set — SSL detection in ldpaths failed")
  if (!file.exists(ca)) stop(paste("CURL_CA_BUNDLE points to missing file:", ca))
  cat(sprintf("CURL_CA_BUNDLE=%s (OK)\n", ca))
'

echo "=== Verify Tcl/Tk bundled scripts ==="
"${R_HOME}/bin/Rscript" -e '
  tcl_lib <- Sys.getenv("TCL_LIBRARY")
  tk_lib <- Sys.getenv("TK_LIBRARY")
  if (nchar(tcl_lib) == 0) stop("TCL_LIBRARY is not set")
  if (nchar(tk_lib) == 0) stop("TK_LIBRARY is not set")
  if (!file.exists(file.path(tcl_lib, "init.tcl"))) stop(paste("init.tcl not found in", tcl_lib))
  cat(sprintf("TCL_LIBRARY=%s (OK)\nTK_LIBRARY=%s (OK)\n", tcl_lib, tk_lib))
'

echo "=== Relocatability test ==="
RELOCATED_DIR="/tmp/R-relocated-${R_VERSION}"
cp -a "${R_PREFIX}" "${RELOCATED_DIR}"
rm -rf "${R_PREFIX}"
"${RELOCATED_DIR}/bin/R" -e 'cat("Relocatability: bin/R works\n")' --vanilla

echo "=== R CMD INSTALL from relocated path ==="
# This tests that lib/R/bin/R is also patched (used by R CMD INSTALL internally).
DIR=$SCRIPT_DIR "${RELOCATED_DIR}/bin/Rscript" -e '
  temp_lib <- tempdir()
  .libPaths(temp_lib)
  curr_dir <- Sys.getenv("DIR", ".")
  pkg <- file.path(curr_dir, "testpkg")
  if (dir.exists(pkg)) {
    install.packages(pkg, repos = NULL, lib = temp_lib, clean = TRUE)
    library(testpkg, lib.loc = temp_lib)
    cat("R CMD INSTALL from relocated path: OK\n")
  } else {
    cat("testpkg not found, skipping R CMD INSTALL test\n")
  }
' --vanilla

echo "=== HTTPS download from relocated path ==="
"${RELOCATED_DIR}/bin/Rscript" -e '
  f <- tempfile()
  tryCatch({
    download.file("https://cloud.r-project.org", f, quiet = TRUE)
    cat("HTTPS download from relocated path: OK\n")
  }, error = function(e) {
    stop(paste("HTTPS download failed:", e$message))
  })
' --vanilla

# Restore original location for any further tests
mv "${RELOCATED_DIR}" "${R_PREFIX}"

echo "=== Verify libRblas/libRlapack SONAME ==="
# libRblas.so must have SONAME "libRblas.so" (not the original "libopenblasp.so.0").
# If wrong, packages that link against -lRblas will record the wrong SONAME and
# fail to load on systems without the matching library.
RBLAS_SONAME=$(readelf -d "${R_HOME}/lib/libRblas.so" 2>/dev/null | sed -n 's/.*\(SONAME\).*\[\(.*\)\]/\2/p')
if [ "$RBLAS_SONAME" != "libRblas.so" ]; then
  echo "FAIL: libRblas.so has SONAME '$RBLAS_SONAME', expected 'libRblas.so'"
  exit 1
fi
echo "  libRblas.so SONAME: $RBLAS_SONAME (OK)"

# libRblas must NOT be in .libs/ (it lives in lib/R/lib/ and is loaded via LD_LIBRARY_PATH)
if ls "${R_PREFIX}"/lib/R/lib/.libs/*Rblas* 2>/dev/null; then
  echo "FAIL: libRblas.so should not be bundled in .libs/"
  exit 1
fi
echo "  libRblas.so not in .libs/ (OK)"

# Verify testpkg.so links against libRblas.so (not libopenblasp.so.0)
TESTPKG_SO=$(find "${R_PREFIX}" -path "*/testpkg/libs/testpkg.so" 2>/dev/null | head -1)
if [ -n "$TESTPKG_SO" ]; then
  if readelf -d "$TESTPKG_SO" | grep -q "libopenblasp"; then
    echo "FAIL: testpkg.so links against libopenblasp instead of libRblas"
    exit 1
  fi
  echo "  testpkg.so DT_NEEDED: OK (no libopenblasp reference)"
fi

echo "=== All manylinux_2_28 tests passed ==="
