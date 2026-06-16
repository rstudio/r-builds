#!/usr/bin/env bash
set -euo pipefail

# notarize.sh — Submit a macOS R build to Apple's notary service.
# Requires Developer ID signed binaries (CODESIGN_IDENTITY must have
# been set during build) and Apple credentials.

OUTPUT_DIR="${1:?Usage: notarize.sh <r-output-dir>}"
OUTPUT_DIR="$(cd "${OUTPUT_DIR}" && pwd)"

APPLE_ID="${APPLE_ID:?APPLE_ID is required}"
APPLE_APP_PASSWORD="${APPLE_APP_PASSWORD:?APPLE_APP_PASSWORD is required}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:?APPLE_TEAM_ID is required}"

echo "=== Notarizing ${OUTPUT_DIR} ==="

# xcrun notarytool requires zip, dmg, or pkg
NOTARIZE_ZIP="${OUTPUT_DIR}-notarize.zip"
ditto -c -k --keepParent "${OUTPUT_DIR}" "${NOTARIZE_ZIP}"
echo "  Created notarization zip: ${NOTARIZE_ZIP}"

echo "  Submitting to Apple notary service..."
NOTARIZE_OUTPUT=$(xcrun notarytool submit "${NOTARIZE_ZIP}" \
  --apple-id "${APPLE_ID}" \
  --password "${APPLE_APP_PASSWORD}" \
  --team-id "${APPLE_TEAM_ID}" \
  --wait 2>&1) || true

echo "${NOTARIZE_OUTPUT}"

if echo "${NOTARIZE_OUTPUT}" | grep -q "status: Accepted"; then
  echo "=== Notarization accepted by Apple ==="
elif echo "${NOTARIZE_OUTPUT}" | grep -q "status: Invalid"; then
  SUBMISSION_ID=$(echo "${NOTARIZE_OUTPUT}" | grep "  id:" | head -1 | awk '{print $2}')
  if [ -n "${SUBMISSION_ID}" ]; then
    echo "  Notarization rejected — fetching log:"
    xcrun notarytool log "${SUBMISSION_ID}" \
      --apple-id "${APPLE_ID}" \
      --password "${APPLE_APP_PASSWORD}" \
      --team-id "${APPLE_TEAM_ID}" 2>&1 || true
  fi
  echo "ERROR: Notarization failed" >&2
  rm -f "${NOTARIZE_ZIP}"
  exit 1
else
  echo "ERROR: Notarization status unknown" >&2
  rm -f "${NOTARIZE_ZIP}"
  exit 1
fi

rm -f "${NOTARIZE_ZIP}"
