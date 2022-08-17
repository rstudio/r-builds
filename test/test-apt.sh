#!/usr/bin/env bash
set -ex

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

# Install quick install script prerequisites
if ! command -v curl > /dev/null 2>&1; then
    apt update -qq
    apt install -y curl
fi

# Run the quick install script. Use a locally built file if present, otherwise from the CDN.
tmpdir=$(mktemp -d)
cp -r "${SCRIPT_DIR}/../builder/integration/tmp/${OS_IDENTIFIER}/." "$tmpdir" > /dev/null 2>&1 || true
(cd "$tmpdir" && SCRIPT_ACTION=install R_VERSION="${R_VERSION}" RUN_UNATTENDED=1 "${SCRIPT_DIR}/../install.sh")

# Show DEB info
apt show "r-${R_VERSION}"

"${SCRIPT_DIR}/test-r.sh"

apt remove -y "r-${R_VERSION}"

if [ -d "/opt/R/${R_VERSION}" ]; then
    echo "Failed to uninstall completely"
    exit 1
fi
