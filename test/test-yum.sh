#!/usr/bin/env bash
set -ex

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

if command -v dnf > /dev/null 2>&1; then
    YUM=dnf
else
    YUM=yum
fi

# Install quick install script prerequisites
if ! command -v curl > /dev/null 2>&1; then
    $YUM install -y curl
fi

# Run the quick install script. Use a locally built file if present, otherwise from the CDN.
tmpdir=$(mktemp -d)
cp -r "${SCRIPT_DIR}/../builder/integration/tmp/${OS_IDENTIFIER}/." "$tmpdir" > /dev/null 2>&1 || true
(cd "$tmpdir" && SCRIPT_ACTION=install R_VERSION="${R_VERSION}" RUN_UNATTENDED=1 "${SCRIPT_DIR}/../install.sh")

# Show rpm info
rpm -qi "R-${R_VERSION}"

"${SCRIPT_DIR}/test-r.sh"

$YUM -y remove "R-${R_VERSION}"

if [ -d "/opt/R/${R_VERSION}" ]; then
    echo "Failed to uninstall completely"
    exit 1
fi

# flexiblas-devel is a weak Recommends on RHEL 9/10 because it is absent from the
# UBI CodeReady Builder subset (RHEL-5411, closed as fixed but never shipped).
# Reproduce UBI by installing with weak deps disabled: the RPM must still install,
# the runtime (flexiblas-netlib) must be present, flexiblas-devel must be skipped,
# and R must run BLAS at runtime. Guards against regressing flexiblas-devel to a
# hard dependency, which would break UBI installs.
case "${OS_IDENTIFIER}" in
  rhel-9|rhel-10)
    pkg_file=$(ls ${SCRIPT_DIR}/../builder/integration/tmp/${OS_IDENTIFIER}/R-${R_VERSION}*.rpm 2>/dev/null | head -1)
    if [ -n "${pkg_file}" ] && rpm -qp --requires "${pkg_file}" | grep -q '^flexiblas'; then
        # The RPM must declare flexiblas-devel as a weak Recommends so full
        # RHEL/Rocky still auto-installs it; a dropped Recommends would otherwise
        # pass the checks below (devel simply absent) while breaking source builds.
        rpm -qp --recommends "${pkg_file}" | grep -q '^flexiblas-devel'

        $YUM -y remove flexiblas-devel > /dev/null 2>&1 || true
        $YUM install -y --setopt=install_weak_deps=False "${pkg_file}"

        # libflexiblas.so.3 (what R loads) comes from flexiblas-netlib, not the
        # flexiblas front-end, so check the SONAME provider directly.
        rpm -q flexiblas
        rpm -q flexiblas-netlib

        # flexiblas-devel (weak dependency) must be skipped, not pulled in.
        if rpm -q flexiblas-devel > /dev/null 2>&1; then
            echo "flexiblas-devel was installed with weak dependencies disabled; it may have regressed to a hard dependency"
            exit 1
        fi

        # R and runtime BLAS must work without flexiblas-devel. (Only source
        # compilation of BLAS-linked packages needs it, so test-r.sh, which
        # builds testpkg against -lflexiblas, is intentionally not run here.)
        R_HOME="/opt/R/${R_VERSION}/lib/R"
        "${R_HOME}/bin/R" --version
        "${R_HOME}/bin/Rscript" -e 'x <- matrix(rnorm(100), 10); stopifnot(is.matrix(crossprod(x))); cat("runtime BLAS OK\n")'

        $YUM -y remove "R-${R_VERSION}"
        if [ -d "/opt/R/${R_VERSION}" ]; then
            echo "Failed to uninstall completely"
            exit 1
        fi
    else
        echo "Skipping flexiblas-devel weak-dependency check: no locally built ${OS_IDENTIFIER} RPM linking flexiblas found"
    fi
    ;;
esac
