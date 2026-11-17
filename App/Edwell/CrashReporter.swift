import EddieKit
import Foundation
import Sentry

/// Anonymous crash reports through Sentry (#51). The rules (the shared user, what gets scrubbed, the
/// environment, the switch in the Help menu) are in EddieKit's `CrashReports`, where the self test checks
/// them; this file applies them to sentry-cocoa and is the only code in Edwell that touches the network.
///
/// Out of the box sentry-cocoa sends a random installation ID as the user and as every session's `did`,
/// and a hash of the Mac's network address and model as `contexts.app.device_app_hash`. Everything below
/// makes sure none of that, and nothing from the user's media or projects, leaves the Mac. Screenshots and
/// the view hierarchy don't exist on macOS in sentry-cocoa 9, so there is nothing to turn off there.
///
/// The privacy policy (website/privacy.html), PrivacyInfo.xcprivacy and the App Store label promise
/// exactly what this sends. Change them together.
enum CrashReporter {
    static let dsn = CrashReports.dsn(in: Bundle.main.infoDictionary)

    /// Called by main.swift before `Launcher.run()`.
    static func install() {
        CrashReports.reporter = CrashReports.Reporter(
            isConfigured: dsn != nil,
            start: { Task { @MainActor in await start() } },
            stop: { Task { @MainActor in if SentrySDK.isEnabled { SentrySDK.close() } } },
            selfCheck: selfCheck,
            sendTestReport: { await sendTestReport() })
    }

    @MainActor
    private static func start() async {
        guard let dsn, !SentrySDK.isEnabled else { return }
        let environment = await CrashReports.currentEnvironment()
        // The switch may have been turned off while StoreKit answered.
        guard CrashReports.isAllowed(), !SentrySDK.isEnabled else { return }
        let options = Options()
        configure(options, dsn: dsn, environment: environment)
        pinInstallationID(cacheDirectoryPath: options.cacheDirectoryPath)
        SentrySDK.start(options: options)
    }

    /// The one place the options are set, for the app and for the self check alike.
    static func configure(_ options: Options, dsn: String, environment: CrashReports.Environment) {
        options.dsn = dsn
        options.environment = environment.rawValue
        #if DEBUG
        options.debug = true
        #endif

        // The shared user is on the scope before any integration starts, so nothing falls back to the
        // installation ID; beforeSend sets it again on every report, crashes from the last run included.
        options.initialScope = { scope in
            scope.setUser(User(userId: CrashReports.anonymousUser))
            return scope
        }
        options.sendDefaultPii = false
        // In sentry-cocoa 9 transactions pass through beforeSend too (beforeSendTransaction comes in 10),
        // so this one callback covers errors, crashes, app hangs, MetricKit and any transaction.
        options.beforeSend = { scrub($0) }
        options.beforeBreadcrumb = { scrub($0) }

        // Crashes, app hangs, and Apple's own hang, CPU and disk-write diagnostics.
        options.enableMetricKit = true
        // Crash-free sessions per release. A session carries a release, an environment, a status and
        // a `did`, which pinInstallationID makes the shared user's (checked against an outgoing envelope).
        options.enableAutoSessionTracking = true

        // Nothing that watches: no tracing (tracesSampleRate stays nil), no network or file tracking.
        options.enableAutoPerformanceTracing = false
        options.enableNetworkTracking = false
        options.enableNetworkBreadcrumbs = false
        options.enableCaptureFailedRequests = false
        options.enableFileIOTracing = false
        options.enableDataSwizzling = false
        options.enableCoreDataTracing = false
        // No feature counts yet (#51 leaves them for later); when they come, beforeSendMetric drops user.id.
        options.enableMetrics = false
        // How many reports the SDK dropped. Not needed.
        options.sendClientReports = false
    }

    // MARK: - Scrubbing

    /// Every report, just before it leaves the Mac.
    static func scrub(_ event: Event) -> Event {
        event.user = User(userId: CrashReports.anonymousUser)
        event.serverName = nil
        event.request = nil
        if let context = event.context {
            event.context = CrashReports.scrub(contexts: context)
        }
        if let message = event.message {
            let clean = SentryMessage(formatted: CrashReports.redact(message.formatted))
            clean.message = message.message.map(CrashReports.redact)
            clean.params = message.params?.map(CrashReports.redact)
            event.message = clean
        }
        for exception in event.exceptions ?? [] {
            exception.value = exception.value.map(CrashReports.redact)
            if let mechanism = exception.mechanism {
                mechanism.desc = mechanism.desc.map(CrashReports.redact)
                mechanism.data = mechanism.data?.mapValues(CrashReports.scrub(value:))
            }
            exception.stacktrace?.frames.forEach(scrub)
        }
        event.threads?.forEach { $0.stacktrace?.frames.forEach(scrub) }
        event.stacktrace?.frames.forEach(scrub)
        event.debugMeta?.forEach { $0.codeFile = $0.codeFile.map(CrashReports.redactHome) }
        event.breadcrumbs = event.breadcrumbs?.map(scrub)
        event.tags = event.tags?.mapValues(CrashReports.redact)
        event.extra = event.extra?.mapValues(CrashReports.scrub(value:))
        event.transaction = event.transaction.map(CrashReports.redact)
        return event
    }

    static func scrub(_ crumb: Breadcrumb) -> Breadcrumb {
        crumb.message = crumb.message.map(CrashReports.redact)
        for (key, value) in crumb.data ?? [:] {
            crumb.setData(value: CrashReports.scrub(value: value), key: key)
        }
        return crumb
    }

    private static func scrub(_ frame: Frame) {
        frame.package = frame.package.map(CrashReports.redactHome)
        frame.fileName = frame.fileName.map(CrashReports.redact)
    }

    /// Sessions can't be given a user: sentry-cocoa 9 sets every session's `did` from the INSTALLATION
    /// file in its cache directory, and writes a random UUID there when the file is missing
    /// (SentryInstallation.swift). Writing the shared user into the file before the SDK starts makes every
    /// Mac report the same `did`. This leans on an SDK detail, so the envelope is checked again before
    /// every sentry-cocoa upgrade (XCODE_CLOUD.md).
    static func pinInstallationID(cacheDirectoryPath: String) {
        let directory = URL(fileURLWithPath: cacheDirectoryPath)
        let url = directory.appendingPathComponent("INSTALLATION")
        let pinned = Data(CrashReports.anonymousUser.utf8)
        guard (try? Data(contentsOf: url)) != pinned else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? pinned.write(to: url, options: .atomic)
    }

    // MARK: - Checks

    /// `Edwell --send-test-report`: one session and one message, sent now, without a window. The message has
    /// a made-up file in the home folder in it, so the report in Sentry shows the redaction worked
    /// (`<path>`) as well as the user and the environment, and the session shows its `did`.
    /// scripts/check-crash-envelopes.py runs it against a stand-in for Sentry on this Mac.
    @MainActor
    private static func sendTestReport() async -> Bool {
        guard let dsn else { return false }
        if !SentrySDK.isEnabled {
            let options = Options()
            configure(options, dsn: dsn, environment: await CrashReports.currentEnvironment())
            // No app run to follow, so the one session is opened and closed by hand below.
            options.enableAutoSessionTracking = false
            pinInstallationID(cacheDirectoryPath: options.cacheDirectoryPath)
            SentrySDK.start(options: options)
        }
        SentrySDK.startSession()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let home = NSHomeDirectoryForUser(NSUserName()) ?? NSHomeDirectory()
        let id = SentrySDK.capture(message: "Test report from Edwell \(version). This file should show as <path>: \(home)/Movies/Test clip.mov")
        SentrySDK.endSession()
        // Waits for the upload; Sentry's own log (debug builds) says how it went.
        SentrySDK.flush(timeout: 15)
        return id != SentryId.empty
    }

    /// For the self test inside Edwell.app: the real options and callbacks on made-up reports with a
    /// home folder, file names, a title and IDs in every place they could hide. Returns what got through.
    static func selfCheck() -> [String] {
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) { if !condition { failures.append(message) } }

        let options = Options()
        configure(options, dsn: "https://0123456789abcdef0123456789abcdef@o0.ingest.de.sentry.io/0", environment: .production)
        check(!options.sendDefaultPii, "sendDefaultPii")
        check(options.enableMetricKit, "MetricKit")
        check(options.tracesSampleRate == nil && !options.isTracingEnabled, "tracing")
        check(!options.enableMetrics && !options.enableNetworkTracking && !options.enableFileIOTracing, "tracking")
        check(options.environment == "production", "environment")
        check(options.beforeSend != nil && options.beforeBreadcrumb != nil, "callbacks")
        let scope = options.initialScope(Scope())
        check((scope.serialize()["user"] as? [String: Any])?["id"] as? String == CrashReports.anonymousUser, "initial user")

        let secrets = ["selftest-user", "Secret Clip", "Wedding Title", "installation-0000", "hash-0000", "device-0000", "Selftest-Mac"]
        let home = "/Users/selftest-user"
        let event = Event(level: .fatal)
        event.user = User(userId: "installation-0000")
        event.serverName = "Selftest-Mac"
        event.context = ["app": ["device_app_hash": "hash-0000", "app_name": "Edwell", "path": "\(home)/Movies/Secret Clip.mov"],
                         "device": ["id": "device-0000", "model": "Mac15,3"]]
        event.message = SentryMessage(formatted: "Could not open \(home)/Movies/Secret Clip.mov")
        let exception = Exception(value: "The file “Secret Clip.mov” couldn’t be opened. UserInfo={NSFilePath=\(home)/Movies/Secret Clip.mov, NSURL=file://\(home)/Movies/Secret%20Clip.mov}", type: "NSCocoaErrorDomain")
        let mechanism = Mechanism(type: "NSException")
        mechanism.desc = "Couldn't save “Wedding Title.edwell”"
        mechanism.data = ["reason": "\(home)/Desktop/Wedding Title.edwell"]
        exception.mechanism = mechanism
        event.exceptions = [exception]
        let frame = Frame()
        frame.package = "\(home)/Applications/Edwell.app/Contents/MacOS/Edwell"
        let thread = SentryThread(threadId: 0)
        thread.stacktrace = SentryStacktrace(frames: [frame], registers: [:])
        event.threads = [thread]
        let image = DebugMeta()
        image.codeFile = "\(home)/Applications/Edwell.app/Contents/MacOS/Edwell"
        event.debugMeta = [image]
        let crumb = Breadcrumb(level: .info, category: "file")
        crumb.message = "Opened \(home)/Movies/Secret Clip.mov"
        crumb.setData(value: "file://\(home)/Movies/Secret%20Clip.mov", key: "url")
        event.breadcrumbs = [crumb]
        event.tags = ["file": "~/Movies/Secret Clip.mov"]
        event.extra = ["files": ["/Volumes/selftest-user/Secret Clip.mov"]]

        guard let sent = options.beforeSend?(event),
              let json = try? JSONSerialization.data(withJSONObject: sent.serialize()),
              let text = String(data: json, encoding: .utf8) else {
            return failures + ["beforeSend dropped the event"]
        }
        for secret in secrets { check(!text.contains(secret), "\(secret) in \(text)") }
        check(sent.user?.userId == CrashReports.anonymousUser, "user \(sent.user?.userId ?? "nil")")
        check(sent.context?["app"]?["app_name"] as? String == "Edwell" && sent.context?["device"]?["model"] as? String == "Mac15,3",
              "the coarse facts went too")
        check(sent.debugMeta?.first?.codeFile == "~/Applications/Edwell.app/Contents/MacOS/Edwell", "binary path \(sent.debugMeta?.first?.codeFile ?? "nil")")
        let fresh = Breadcrumb(level: .info, category: "file")
        fresh.message = "Saved \(home)/Desktop/Wedding Title.edwell"
        check(options.beforeBreadcrumb?(fresh)?.message?.contains("selftest-user") == false, "breadcrumb")

        // A cache folder that already has someone's installation ID ends up with the shared user.
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("installation-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try? Data(UUID().uuidString.utf8).write(to: cache.appendingPathComponent("INSTALLATION"))
        pinInstallationID(cacheDirectoryPath: cache.path)
        let pinned = try? String(contentsOf: cache.appendingPathComponent("INSTALLATION"), encoding: .utf8)
        check(pinned == CrashReports.anonymousUser, "INSTALLATION \(pinned ?? "nil")")
        try? FileManager.default.removeItem(at: cache)
        return failures
    }
}
