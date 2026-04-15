#!/usr/bin/env bash
set -ex

# Test script for manylinux portable R builds.
# Runs on various distros to validate cross-distro portability.
#
# Tested distros: Ubuntu Noble, Rocky Linux 9, Rocky Linux 10, openSUSE 15.6
#
# This script:
# 1. Installs R from the tarball (not DEB/RPM)
# 2. Installs distro-appropriate build tools and runtime deps
# 3. Runs the standard test suite (test-r.sh → test.R)
# 4. Runs manylinux-specific tests (relocatability, R CMD INSTALL, SSL)

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
TEST_DIR="${SCRIPT_DIR}/../../test"

# Install R from the tarball.
TARBALL_DIR="${SCRIPT_DIR}/../integration/tmp/r/${OS_IDENTIFIER}"
TARBALL=$(ls "${TARBALL_DIR}"/R-${R_VERSION}*.tar.gz 2>/dev/null | head -1)

if [ -z "$TARBALL" ]; then
  echo "ERROR: No tarball found for R ${R_VERSION} in ${TARBALL_DIR}"
  ls -la "${TARBALL_DIR}/" 2>/dev/null || echo "  Directory does not exist"
  exit 1
fi

# Install build tools and runtime dependencies.
# These are the manylinux allowed libs (not bundled) plus dev tools
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
    fontconfig dejavu-fonts
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
"${TEST_DIR}/test-r.sh"

# Manylinux-specific tests below.
#
# NOTE: All Rscript -e calls must be single-line and must not contain \n
# escape sequences. R <= 3.5.x's Rscript mangles multi-line -e arguments
# and treats \n as a literal newline, splitting the argument. Use writeLines()
# instead of cat("...\n"), and use temp .R files for longer tests.
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
  echo "WARNING: No .libs directory found — delocate_r.py may not have bundled anything"
fi

echo "=== Verify SSL CA detection ==="
"${R_HOME}/bin/Rscript" -e 'ca <- Sys.getenv("CURL_CA_BUNDLE"); if (nchar(ca) == 0) stop("CURL_CA_BUNDLE is not set"); if (!file.exists(ca)) stop(paste("CURL_CA_BUNDLE points to missing file:", ca)); writeLines(paste("CURL_CA_BUNDLE", ca, "(OK)"))'

echo "=== Verify SSL CA detection with --vanilla ==="
"${R_HOME}/bin/Rscript" --vanilla -e 'ca <- Sys.getenv("CURL_CA_BUNDLE"); if (nchar(ca) == 0) stop("CURL_CA_BUNDLE is not set with --vanilla"); if (!file.exists(ca)) stop(paste("CURL_CA_BUNDLE points to missing file:", ca)); writeLines(paste("CURL_CA_BUNDLE", ca, "(--vanilla OK)"))'

echo "=== Verify Tcl/Tk bundled scripts ==="
"${R_HOME}/bin/Rscript" -e 'tcl_lib <- Sys.getenv("TCL_LIBRARY"); tk_lib <- Sys.getenv("TK_LIBRARY"); if (nchar(tcl_lib) == 0) stop("TCL_LIBRARY is not set"); if (nchar(tk_lib) == 0) stop("TK_LIBRARY is not set"); if (!file.exists(file.path(tcl_lib, "init.tcl"))) stop(paste("init.tcl not found in", tcl_lib)); writeLines(paste("TCL_LIBRARY", tcl_lib, "(OK)")); writeLines(paste("TK_LIBRARY", tk_lib, "(OK)"))'

echo "=== Verify Tcl/Tk bundled scripts with --vanilla ==="
"${R_HOME}/bin/Rscript" --vanilla -e 'tcl_lib <- Sys.getenv("TCL_LIBRARY"); tk_lib <- Sys.getenv("TK_LIBRARY"); if (nchar(tcl_lib) == 0) stop("TCL_LIBRARY is not set with --vanilla"); if (nchar(tk_lib) == 0) stop("TK_LIBRARY is not set with --vanilla"); writeLines(paste("TCL_LIBRARY", tcl_lib, "(--vanilla OK)")); writeLines(paste("TK_LIBRARY", tk_lib, "(--vanilla OK)"))'

echo "=== Relocatability test ==="
RELOCATED_DIR="/tmp/R-relocated-${R_VERSION}"
cp -a "${R_PREFIX}" "${RELOCATED_DIR}"
rm -rf "${R_PREFIX}"
"${RELOCATED_DIR}/bin/Rscript" --vanilla -e 'writeLines("Relocatability: bin/R works")'

echo "=== R CMD INSTALL from relocated path ==="
# This tests that lib/R/bin/R is also patched (used by R CMD INSTALL internally).
cat > /tmp/test_relocated_install.R <<'REOF'
temp_lib <- tempdir()
.libPaths(temp_lib)
curr_dir <- Sys.getenv("DIR", ".")
pkg <- file.path(curr_dir, "testpkg")
if (file.exists(pkg)) {
  install.packages(pkg, repos = NULL, lib = temp_lib, clean = TRUE)
  library(testpkg, lib.loc = temp_lib)
  cat("R CMD INSTALL from relocated path: OK\n")
} else {
  cat("testpkg not found, skipping R CMD INSTALL test\n")
}
REOF
DIR=$TEST_DIR "${RELOCATED_DIR}/bin/Rscript" --vanilla /tmp/test_relocated_install.R

echo "=== HTTPS download from relocated path ==="
# method="libcurl" was added in R 3.2. Skip this test for older R.
if "${RELOCATED_DIR}/bin/Rscript" --vanilla -e 'if (getRversion() < "3.2") q("no", status = 1)'; then
  "${RELOCATED_DIR}/bin/Rscript" --vanilla -e 'f <- tempfile(); tryCatch({ download.file("https://cloud.r-project.org", f, method = "libcurl", quiet = TRUE); writeLines("HTTPS download from relocated path: OK") }, error = function(e) { stop(paste("HTTPS download failed:", e$message)) })'
else
  echo "  Skipped (R < 3.2 does not support method=libcurl)"
fi

# Restore original location for any further tests
mv "${RELOCATED_DIR}" "${R_PREFIX}"

echo "=== Verify OpenBLAS is linked (not reference BLAS) ==="
# libRblas.so should be OpenBLAS (not R's reference implementation).
# libRlapack.so should not exist (LAPACK is provided by OpenBLAS via libRblas.so).
# Verify by checking for the openblas_get_config symbol, which only exists in OpenBLAS.
if ! nm -D "${R_HOME}/lib/libRblas.so" 2>/dev/null | grep -q openblas_get_config; then
  echo "FAIL: libRblas.so does not contain openblas_get_config -- not linked to OpenBLAS"
  exit 1
fi
echo "  libRblas.so: contains OpenBLAS (OK)"
# Verify libRlapack.so does not exist (all LAPACK routines come from libRblas.so)
if [ -e "${R_HOME}/lib/libRlapack.so" ]; then
  echo "FAIL: libRlapack.so should not exist (LAPACK is provided by libRblas.so)"
  exit 1
fi
echo "  libRlapack.so does not exist (OK)"
# Verify LAPACK_LIBS is empty in Makeconf (matches RHEL 9's flexiblas behavior)
LAPACK_LIBS_VAL=$(grep '^LAPACK_LIBS' "${R_HOME}/etc/Makeconf" | sed 's/^LAPACK_LIBS = *//')
if [ -n "$LAPACK_LIBS_VAL" ]; then
  echo "FAIL: LAPACK_LIBS should be empty, got '$LAPACK_LIBS_VAL'"
  exit 1
fi
echo "  Makeconf LAPACK_LIBS is empty (OK)"
# Verify R reports the BLAS/LAPACK paths within R_HOME.
# Since OpenBLAS provides both BLAS and LAPACK via libRblas.so, R should
# report both BLAS and LAPACK pointing to libRblas.so.
"${R_HOME}/bin/Rscript" -e 'si <- sessionInfo(); blas <- si$BLAS; lapack <- si$LAPACK; if (is.null(blas) || nchar(blas) == 0) { writeLines("  BLAS/LAPACK: not reported by sessionInfo (old R), skipping") } else { writeLines(paste("  BLAS:", blas)); writeLines(paste("  LAPACK:", lapack)); if (!grepl("libRblas", blas)) stop("sessionInfo()$BLAS does not point to libRblas.so"); if (!grepl("libRblas", lapack)) stop("sessionInfo()$LAPACK does not point to libRblas.so") }'

echo "=== Verify libRblas SONAME ==="
# libRblas.so must have SONAME "libRblas.so" (not the original "libopenblaso.so.0").
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

# Verify testpkg.so links against libRblas.so (not libopenblaso.so.0)
TESTPKG_SO=$(find "${R_PREFIX}" -path "*/testpkg/libs/testpkg.so" 2>/dev/null | head -1)
if [ -n "$TESTPKG_SO" ]; then
  if readelf -d "$TESTPKG_SO" | grep -q "libopenblaso"; then
    echo "FAIL: testpkg.so links against libopenblaso instead of libRblas"
    exit 1
  fi
  echo "  testpkg.so DT_NEEDED: OK (no libopenblaso reference)"
fi

echo "=== Rscript wrapper tests ==="
# Test key usage patterns of the relocatable Rscript shell wrapper to catch
# regressions if upstream Rscript changes its CLI interface.
RSCRIPT="${R_PREFIX}/bin/Rscript"

# -e expression
result=$("$RSCRIPT" -e 'cat("hello")')
[ "$result" = "hello" ] || { echo "FAIL: Rscript -e"; exit 1; }
echo "  Rscript -e: OK"

# Multiple -e expressions
result=$("$RSCRIPT" -e 'cat("a")' -e 'cat("b")')
[ "$result" = "ab" ] || { echo "FAIL: Rscript -e -e"; exit 1; }
echo "  Rscript -e -e: OK"

# File execution with arguments
tmpscript=$(mktemp /tmp/test_rscript_XXXXXX.R)
echo 'args <- commandArgs(trailingOnly=TRUE); cat(paste(args, collapse=","))' > "$tmpscript"
result=$("$RSCRIPT" "$tmpscript" arg1 arg2 arg3)
[ "$result" = "arg1,arg2,arg3" ] || { echo "FAIL: Rscript file args: got '$result'"; exit 1; }
echo "  Rscript file.R arg1 arg2 arg3: OK"

# --default-packages
result=$("$RSCRIPT" --default-packages=base -e 'cat(paste(.packages(), collapse=","))')
echo "$result" | grep -q "base" || { echo "FAIL: --default-packages: got '$result'"; exit 1; }
echo "  Rscript --default-packages=base: OK"

# --vanilla pass-through
result=$("$RSCRIPT" --vanilla -e 'cat("vanilla")')
[ "$result" = "vanilla" ] || { echo "FAIL: Rscript --vanilla"; exit 1; }
echo "  Rscript --vanilla: OK"

# Rscript with no args should not hang (runs R --slave --no-restore, which exits)
timeout 10 "$RSCRIPT" < /dev/null > /dev/null 2>&1 || { echo "FAIL: Rscript with no args hung or failed"; exit 1; }
echo "  Rscript (no args): OK"

rm -f "$tmpscript"

echo "=== All manylinux tests passed ==="
