#!/usr/bin/env bash
set -ex

PKG_FILE=/packages/${OS_IDENTIFIER}/r-${R_VERSION}_1_amd64.deb

if [ ! -f ${PKG_FILE} ]; then
    echo "No package found, skipping tests"
    exit 0
fi

export DEBIAN_FRONTEND=noninteractive 
apt-get update -qq
apt-get install -f -y ${PKG_FILE}

# Show deb info
apt-cache show r-${R_VERSION}

/test/test-r.sh

apt-get remove -y r-${R_VERSION}

if [ -d /opt/R/${R_VERSION} ]; then
    echo "Failed to uninstall completely"
    exit 1
fi
