#!/usr/bin/env bash
set -ex

# Test script for manylinux-2-28 portable R builds.
# Runs on a different distro (e.g., Ubuntu 20.04) to validate cross-distro portability.
#
# This script installs R from the tarball (not an RPM/DEB) and runs basic tests.

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

# Install R from the tarball built by the manylinux-2-28 platform.
# The tarball is at /r-builds/builder/integration/tmp/r/manylinux-2-28/R-${R_VERSION}-manylinux-2-28.tar.gz
TARBALL_DIR="${SCRIPT_DIR}/../builder/integration/tmp/r/manylinux-2-28"
TARBALL=$(ls "${TARBALL_DIR}"/R-${R_VERSION}*.tar.gz 2>/dev/null | head -1)

if [ -z "$TARBALL" ]; then
  echo "ERROR: No tarball found for R ${R_VERSION} in ${TARBALL_DIR}"
  ls -la "${TARBALL_DIR}/" 2>/dev/null || echo "  Directory does not exist"
  exit 1
fi

echo "Installing R from tarball: ${TARBALL}"
mkdir -p /opt/R
tar xzf "${TARBALL}" -C /opt/R

# Install build tools for R package compilation tests (not included in minimal images).
# Also install development libraries that R's Makeconf references (hardcoded from
# the build host). This simulates a user with standard development tools installed.
echo "Installing build tools (may take a minute)..."
export DEBIAN_FRONTEND=noninteractive
if command -v apt-get &>/dev/null; then
  apt-get update -qq 2>/dev/null && apt-get install -y --no-install-recommends \
    build-essential gfortran ca-certificates less \
    libpcre2-dev liblzma-dev libbz2-dev zlib1g-dev libicu-dev \
    libx11-6 libxt6 tcl tk \
    libcairo2 libpango-1.0-0 libpangocairo-1.0-0 libglib2.0-0 \
    2>/dev/null || echo "WARNING: Some build tools failed to install, package compilation tests may fail"
elif command -v yum &>/dev/null; then
  yum install -y -q gcc gcc-c++ gcc-gfortran make \
    pcre2-devel xz-devel bzip2-devel zlib-devel libicu-devel \
    2>/dev/null || echo "WARNING: Some build tools failed to install, package compilation tests may fail"
fi
echo "Build tools installation done."

R_PREFIX=/opt/R/${R_VERSION}
R_HOME=${R_PREFIX}/lib/R

echo "=== R version ==="
"${R_HOME}/bin/R" --version

echo "=== sessionInfo ==="
"${R_HOME}/bin/Rscript" -e 'sessionInfo()'

echo "=== Shared library dependencies (libR.so) ==="
ldd "${R_HOME}/lib/libR.so" || true

echo "=== Shared library dependencies (exec binary) ==="
ldd "${R_HOME}/bin/exec/R" || true

echo "=== RPATH on exec binary ==="
readelf -d "${R_HOME}/bin/exec/R" | grep -i 'rpath\|runpath' || true

echo "=== R capabilities ==="
"${R_HOME}/bin/Rscript" -e 'print(capabilities())'

echo "=== Test R core functionality ==="
DIR=$SCRIPT_DIR "${R_HOME}/bin/Rscript" "${SCRIPT_DIR}/test.R"

echo "=== Relocatability test ==="
RELOCATED_DIR="/tmp/R-relocated-${R_VERSION}"
cp -a "${R_PREFIX}" "${RELOCATED_DIR}"
rm -rf "${R_PREFIX}"
"${RELOCATED_DIR}/bin/R" -e 'cat("Relocatability test passed\n")' --vanilla
# Restore original location for any further tests
mv "${RELOCATED_DIR}" "${R_PREFIX}"

echo "=== All manylinux-2-28 tests passed ==="
