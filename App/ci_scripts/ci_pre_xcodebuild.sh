#!/bin/sh

# Xcode Cloud runs this before building; it looks for ci_scripts next to Edwell.xcodeproj.
# Sets a unique, incrementing build number from the Cloud build number so every TestFlight
# upload is accepted. A no-op outside Xcode Cloud (CI_BUILD_NUMBER is unset).

set -e

if [ -n "$CI_BUILD_NUMBER" ] && [ -n "$CI_PRIMARY_REPOSITORY_PATH" ]; then
    echo "Setting build number to $CI_BUILD_NUMBER"
    cd "$CI_PRIMARY_REPOSITORY_PATH/App"
    agvtool new-version -all "$CI_BUILD_NUMBER"
else
    echo "Not in Xcode Cloud, leaving the build number unchanged."
fi

# Crash reports (#51). The DSN is a secret on the workflow, never in git. An archive without it would
# ship with crash reports silently off, so the archive stops here; builds and tests go on without it.
# With it, it goes into Info.plist for this build only, where CrashReporter.swift reads it. The DSN is
# never printed.
if [ "$CI_XCODEBUILD_ACTION" = "archive" ]; then
    case "$SENTRY_DSN" in
        https://?*@?*/?*) ;;
        *)
            echo "error: SENTRY_DSN is missing or not a DSN on this Xcode Cloud workflow, so this archive would ship without crash reports. Add it under Environment as a secret (XCODE_CLOUD.md), then build again."
            exit 1
            ;;
    esac
    plutil -replace SentryDSN -string "$SENTRY_DSN" "$CI_PRIMARY_REPOSITORY_PATH/App/Edwell/Info.plist"
    echo "Sentry DSN set for this archive."
fi
