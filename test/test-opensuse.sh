#!/usr/bin/env bash
set -ex

PKG_FILE=/packages/${OS_IDENTIFIER}/R-${R_VERSION}-1-1.x86_64.rpm

if [ ! -f ${PKG_FILE} ]; then
    echo "No package found, skipping tests"
    exit 0
fi

zypper --non-interactive --no-gpg-checks install ${PKG_FILE}

# Show rpm info
rpm -qi R-${R_VERSION}

/test/test-r.sh

zypper --non-interactive remove R-${R_VERSION}

if [ -d /opt/R/${R_VERSION} ]; then
    echo "Failed to uninstall completely"
    exit 1
fi
