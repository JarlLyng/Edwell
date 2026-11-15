# Xcode Cloud

For **maintainers**. How Edwell, the Mac App Store build of Eddie, gets archived and uploaded.

## Where the configuration lives

**Workflows live in App Store Connect, not in this repo.** Nothing in git controls them. `App/ci_scripts/`
and this file are the only traces Xcode Cloud leaves here, so their presence says nothing about whether a
workflow exists or which branch it builds. Look in:

- **App Store Connect** → Xcode Cloud, to see whether the product exists at all.
- **Xcode** → Report Navigator (**⌘9**) → **Cloud**, to create or edit workflows.

## What Xcode Cloud builds

- **Project:** `App/Edwell.xcodeproj`, generated from `App/project.yml` with
  [XcodeGen](https://github.com/yonaskolb/XcodeGen) and committed, because Xcode Cloud builds what is in
  git. Run `cd App && xcodegen generate` after changing `project.yml`. Swift files go in the package
  (`Sources/EddieKit`), so adding one needs no regeneration.
- **Scheme:** `Edwell` (shared, committed in `Edwell.xcodeproj/xcshareddata`).
- **Scripts:** `App/ci_scripts/`, next to the project, which is where Xcode Cloud looks for them.
  `ci_pre_xcodebuild.sh` sets the build number from `CI_BUILD_NUMBER` and, for an archive, puts the
  Sentry DSN into Info.plist (or stops the archive without one). `ci_post_xcodebuild.sh` uploads the
  archive's dSYMs to Sentry.
- **Packages:** the project's pins are in `App/Edwell.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
  (sentry-cocoa and the design system). Xcode resolves from that file, also with automatic package
  resolution turned off, as Xcode Cloud runs it, and fails if it's missing a package. The root
  `Package.resolved` is the package's own, for `swift build`, which would drop Sentry from a shared file.
  The self test checks the design system has the same pin in both.

## Before the first workflow

- The bundle id `com.iamjarl.edwell` is registered, and the App Store Connect record
  "Edwell: Video Editor" exists.
- Signed in to Xcode with an account that can create apps (Account Holder, Admin or App Manager).
- The repository is connected to Xcode Cloud through GitHub.

## The workflow

- **Start condition:** branch changes on **`release`**, like the other IAMJARL apps. `main` is the
  development branch and never starts a release build.
- **Action:** Archive, macOS, scheme `Edwell`, deployment preparation **TestFlight and App Store**.
- **Post-action:** TestFlight internal testing.
- **Environment**, both marked **Secret** (#51):
  - `SENTRY_DSN`: the DSN of the Sentry project `edwell` (organisation `iamjarl`, EU region), from
    Sentry › Settings › Projects › edwell › Client Keys. It goes into the archive's Info.plist and nowhere
    in git. **An archive without it stops** with an error from `ci_pre_xcodebuild.sh`, so a release can't
    ship with crash reports silently off. Builds and tests run without it.
  - `SENTRY_AUTH_TOKEN`: an organisation auth token from Sentry › Settings › Auth Tokens, which can upload
    debug files. `ci_post_xcodebuild.sh` uploads the archive's dSYMs with a pinned, checksum-checked
    `sentry-cli` to `https://de.sentry.io`, so crashes show Edwell's own function names. Without the token,
    or if the upload fails, the build goes on with a warning; only that release's crash reports are
    harder to read. `SENTRY_ORG`, `SENTRY_PROJECT` and `SENTRY_URL` default to `iamjarl`, `edwell` and
    `https://de.sentry.io`.

## Crash reports

Edwell sends anonymous crash reports to Sentry from the release after 1.1 (`App/Edwell/CrashReporter.swift`,
the rules in `Sources/EddieKit/CrashReports.swift`, `AGENTS.md` › Gotchas). A build reports as `production`
only when the App Store installed it; TestFlight is `testflight`, and builds from Xcode or `./build.sh` are
`development`.

**Checking a release build by hand.** Install it from TestFlight (or the App Store), then run in Terminal:

```bash
/Applications/Edwell.app/Contents/MacOS/Edwell --send-test-report
```

It sends one session and one message, without opening a window, and says whether Sentry took them. In
Sentry the message should show `user.id` `anonymous`, no `device_app_hash`, the right environment, and the
made-up file in it as `<path>`.

**Before every sentry-cocoa upgrade**, check the envelopes again, because a session's `did` is the shared
user only through an SDK detail (the `INSTALLATION` file, `CrashReporter.pinInstallationID`). Build with a
DSN that points at this Mac, then run the check, which stands in for Sentry on that port and fails on any
installation ID, device ID, home folder or account name:

```bash
SENTRY_DSN=http://0123456789abcdef0123456789abcdef@127.0.0.1:8970/1 ./build.sh
python3 -I scripts/check-crash-envelopes.py build/Edwell.app
./build.sh
```

Last checked with sentry-cocoa 9.33.0 on 2026-11-15: passed (the session's `did` and the event's user were
`anonymous`). The last `./build.sh` takes the local DSN out of `build/Edwell.app` again. The version is
exact in `App/project.yml`, so an upgrade is always a deliberate change.

## Cutting a release

1. Bump `MARKETING_VERSION` in `App/project.yml` and run `xcodegen generate`.
2. Merge to `main`.
3. Push `main:release`.

## Archiving by hand

To check an archive before a workflow exists, or to validate one. An archive needs a DSN (the build phase
*Check the Sentry DSN* stops one without), so pass it on the command line; it never goes in a file:

```bash
xcodebuild archive -project App/Edwell.xcodeproj -scheme Edwell -archivePath build/Edwell.xcarchive SENTRY_DSN="$SENTRY_DSN"
open build/Edwell.xcarchive   # Organizer → Validate App
```

**Reference:** [Xcode Cloud documentation](https://developer.apple.com/documentation/Xcode/Xcode-Cloud/)
