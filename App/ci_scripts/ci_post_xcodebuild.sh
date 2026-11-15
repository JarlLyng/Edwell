#!/bin/sh

# Xcode Cloud runs this after every xcodebuild action. After an archive it uploads the archive's dSYMs
# to Sentry, so crash reports arrive with Edwell's own function names in them (#51). Needs
# SENTRY_AUTH_TOKEN, a secret on the workflow; the token never goes in the repo. The project is in
# Sentry's EU region, so uploads go to de.sentry.io. Without the token, or if the upload fails, the
# build goes on with a warning: the release is fine, only its crash reports are harder to read.

set -e

[ "$CI_XCODEBUILD_ACTION" = "archive" ] || exit 0

if [ -z "$SENTRY_AUTH_TOKEN" ]; then
    echo "warning: SENTRY_AUTH_TOKEN is not set, so the dSYMs were not uploaded to Sentry (XCODE_CLOUD.md)."
    exit 0
fi

# sentry-cli, pinned and checked against the SHA-256 GitHub publishes for the release asset.
CLI_VERSION="3.8.2"
CLI_SHA256="2d1b118fa46960ba5e8e0cca9a6e197366905776a0ddc5a89c7d05a3908b77db"
CLI="${CI_DERIVED_DATA_PATH:-${TMPDIR:-/tmp}}/sentry-cli"

if ! curl -sSfL -o "$CLI" "https://github.com/getsentry/sentry-cli/releases/download/${CLI_VERSION}/sentry-cli-Darwin-universal"; then
    echo "warning: could not download sentry-cli ${CLI_VERSION}, so the dSYMs were not uploaded."
    exit 0
fi
if ! echo "${CLI_SHA256}  ${CLI}" | shasum -a 256 -c - >/dev/null; then
    echo "warning: sentry-cli's checksum didn't match, so the dSYMs were not uploaded."
    rm -f "$CLI"
    exit 0
fi
chmod +x "$CLI"

if SENTRY_URL="${SENTRY_URL:-https://de.sentry.io}" "$CLI" debug-files upload \
    --org "${SENTRY_ORG:-iamjarl}" \
    --project "${SENTRY_PROJECT:-edwell}" \
    "${CI_ARCHIVE_PATH}/dSYMs"; then
    echo "dSYMs uploaded to Sentry."
else
    echo "warning: the dSYM upload to Sentry failed, so crash reports from this build will be harder to read."
fi
