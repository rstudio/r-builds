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
