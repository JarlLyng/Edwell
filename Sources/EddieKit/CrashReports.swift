import Foundation
import StoreKit

/// Anonymous crash reports (#51), under the portfolio's recipe: one shared user on every Mac, no
/// installation, device or vendor ID, nothing from the user's media or projects, and `production` only
/// for App Store builds. Sentry itself is in the app target (`App/Edwell/CrashReporter.swift`), which
/// links sentry-cocoa and hands EddieKit a `Reporter` before launch. `swift build` has none and sends
/// nothing. The rules live here, without Sentry, so the self test can check them on any Mac.
public enum CrashReports {
    /// What the app target plugs in.
    public struct Reporter {
        /// The build has a DSN. Without one nothing starts and the Help menu has no switch.
        public var isConfigured: Bool
        public var start: () -> Void
        public var stop: () -> Void
        /// For the self test inside Edwell.app: runs made-up reports with paths, names and IDs in them
        /// through the real options and scrubbing, and says what got through. Empty when nothing did.
        public var selfCheck: () -> [String]
        /// `Edwell --send-test-report`: one test report, sent now. Says whether Sentry took it.
        public var sendTestReport: () async -> Bool

        public init(isConfigured: Bool, start: @escaping () -> Void, stop: @escaping () -> Void,
                    selfCheck: @escaping () -> [String], sendTestReport: @escaping () async -> Bool) {
            self.isConfigured = isConfigured
            self.start = start
            self.stop = stop
            self.selfCheck = selfCheck
            self.sendTestReport = sendTestReport
        }
    }

    /// Set by the app target before `Launcher.run()`.
    public static var reporter: Reporter?

    /// The one user every Mac reports as, so no report can be told apart by who sent it.
    public static let anonymousUser = "anonymous"

    // MARK: - The switch

    /// Help › Send Anonymous Crash Reports. Unset means on: the reports carry nothing about the user,
    /// so they need no consent, and the switch is there for anyone who'd rather send nothing.
    static let preferenceKey = "sendCrashReports"

    public static func isAllowed(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: preferenceKey) as? Bool ?? true
    }

    /// Whether the Help menu shows the switch: only in a build that can send.
    static var isAvailable: Bool { reporter?.isConfigured == true }

    /// The switch takes effect at once, not at the next launch.
    static func setAllowed(_ allowed: Bool) {
        UserDefaults.standard.set(allowed, forKey: preferenceKey)
        if allowed { reporter?.start() } else { reporter?.stop() }
    }

    /// At launch of the app. Never in the command-line tests, under XCTest or in the snapshot hook.
    static func startIfAllowed() {
        let environment = ProcessInfo.processInfo.environment
        guard let reporter, reporter.isConfigured, isAllowed(),
              environment["XCTestConfigurationFilePath"] == nil, environment["XCTestSessionIdentifier"] == nil,
              environment["EDDIE_SNAPSHOT"] == nil else { return }
        reporter.start()
    }

    /// `Edwell --send-test-report`, for checking a release build against Sentry by hand (XCODE_CLOUD.md).
    static func sendTestReport() -> Never {
        guard let reporter, reporter.isConfigured else {
            print("This build has no Sentry DSN, so it sends no reports.")
            exit(1)
        }
        Task {
            let sent = await reporter.sendTestReport()
            print(sent ? "Test report sent." : "The test report could not be sent.")
            exit(sent ? 0 : 1)
        }
        Launcher.runMainQueue()
    }

    // MARK: - Where reports go

    public static let dsnKey = "SentryDSN"

    /// The DSN the build put in Info.plist. Empty, or a `$(SENTRY_DSN)` that was never filled in, means none.
    public static func dsn(in info: [String: Any]?) -> String? {
        guard let value = (info?[dsnKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, !value.contains("$("),
              let url = URL(string: value), url.scheme == "https" || url.scheme == "http",
              url.user?.isEmpty == false, url.host?.isEmpty == false else { return nil }
        return value
    }

    /// `production` is only what the App Store installed. TestFlight is `testflight`, and builds from Xcode
    /// or signed on this Mac are `development`, so test runs are never read as real crashes. When the App
    /// Store can't say, `unknown`, never `production`.
    public enum Environment: String {
        case production, testflight, development, unknown
    }

    static func environment(debugBuild: Bool, localBuild: Bool, appStore: AppStore.Environment?) -> Environment {
        if debugBuild || localBuild { return .development }
        switch appStore {
        case .production?: return .production
        case .sandbox?: return .testflight
        case .xcode?: return .development
        default: return .unknown
        }
    }

    /// On macOS a TestFlight build is the App Store's own binary with a sandbox receipt, and the receipt's
    /// file name doesn't tell them apart (it does on iOS), so this asks StoreKit which store installed it.
    public static func currentEnvironment() async -> Environment {
        #if DEBUG
        let debugBuild = true
        #else
        let debugBuild = false
        #endif
        if debugBuild || Store.isLocalBuild {
            return environment(debugBuild: debugBuild, localBuild: Store.isLocalBuild, appStore: nil)
        }
        let appStore: AppStore.Environment?
        switch try? await AppTransaction.shared {
        case .verified(let transaction)?, .unverified(let transaction, _)?: appStore = transaction.environment
        case nil: appStore = nil
        }
        return environment(debugBuild: false, localBuild: false, appStore: appStore)
    }

    // MARK: - Scrubbing

    /// Text the app doesn't write itself (a crash's reason, an error's description, a breadcrumb) can name
    /// the user's files. A path or file URL becomes `<path>`, and a name in Apple's quotes, as in
    /// “Clip.mov”, becomes “<name>”. A path runs to the end of its line or to a quote, a brace or a
    /// semicolon, so a name with spaces, commas or brackets goes whole; that can take some of the words
    /// after it too, which is the price of never leaving half a name behind.
    public static func redact(_ text: String) -> String {
        var result = text
        for (pattern, replacement) in redactions {
            result = pattern.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result),
                                                      withTemplate: replacement)
        }
        return result
    }

    private static let pathEnd = #"[^\n\r\t"“”'‘’{}\[\]<>|;]*"#
    private static let redactions: [(NSRegularExpression, String)] = [
        // file:///Users/… and file://localhost/…, percent-encoded so without spaces.
        (#"file://[^\s"“”'‘’<>]*"#, "<path>"),
        // Where users keep things: their home (and the app's container inside it), other disks and shares,
        // the temporary folders, and a home written as ~.
        (#"(?<![\w.$/~-])(?:/Users/|/Volumes/|/Network/|/private/|/var/|/tmp/|/cores/|~/)"# + pathEnd, "<path>"),
        // Apple's error descriptions put a file's name in curly quotes.
        (#"“[^”\n]*”"#, "“<name>”"),
        (#"‘[^’\n]*’"#, "‘<name>’"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    /// For the paths of the app's own code (a crash's binary images and frames): the home folder, which
    /// has the user's account name in it, becomes `~`. The rest stays, so Sentry can still match them.
    public static func redactHome(_ path: String) -> String {
        guard path.hasPrefix("/Users/") else { return path }
        let rest = path.dropFirst("/Users/".count)
        guard let slash = rest.firstIndex(of: "/") else { return "~" }
        return "~" + rest[slash...]
    }

    /// The contexts the SDK fills in: no vendor-ID hash (on a Mac, a hash of its network address and
    /// model) and no device ID, and no paths in what's left.
    public static func scrub(contexts: [String: [String: Any]]) -> [String: [String: Any]] {
        var scrubbed = contexts
        scrubbed["app"]?["device_app_hash"] = nil
        scrubbed["device"]?["id"] = nil
        return scrubbed.mapValues { $0.mapValues(scrub(value:)) }
    }

    /// Every string in a value, however deep, goes through `redact`.
    public static func scrub(value: Any) -> Any {
        switch value {
        case let string as String: redact(string)
        case let array as [Any]: array.map(scrub(value:))
        case let dictionary as [String: Any]: dictionary.mapValues(scrub(value:))
        default: value
        }
    }
}
