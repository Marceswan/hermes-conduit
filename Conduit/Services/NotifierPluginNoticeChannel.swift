import Foundation
import StoreKit

/// Which plugin versions the update notice asks for (Settings > Conduit
/// plugin > Update notices). Testers want every plugin release; App Store
/// users would otherwise be nagged after each plugin merge between Conduit
/// releases, so they only hear about the stable version.
enum NotifierPluginNoticeChannel: String, CaseIterable, Identifiable {
    /// Every version on TestFlight and Xcode builds, stable on App Store ones.
    case automatic
    /// Every plugin version on main.
    case everyVersion
    /// Only the stable version (notifier main's channels.yaml).
    case stableOnly

    static let key = "conduit.notifierPlugin.noticeChannel"

    var id: String { rawValue }

    static func load(from defaults: UserDefaults) -> NotifierPluginNoticeChannel {
        defaults.string(forKey: key).flatMap(NotifierPluginNoticeChannel.init(rawValue:)) ?? .automatic
    }

    /// Whether the notice asks for every version on main.
    func followsMain(installedFrom source: AppInstallSource) -> Bool {
        switch self {
        // MAC: a self-updating direct download gets stable releases only, like the App Store.
        case .automatic: return source != .appStore && source != .macDirect
        case .everyVersion: return true
        case .stableOnly: return false
        }
    }
}

/// Where this copy of Conduit came from. TestFlight and the App Store ship
/// the same binary, so it is read at run time from the App Store's signed
/// app transaction, not decided when building.
enum AppInstallSource: String {
    case appStore, testFlight, xcode
    /// MAC: a Developer ID build with no App Store receipt that updates itself with Sparkle. Only the Mac makes it.
    case macDirect

    static let key = "conduit.installSource"

    /// The source the last launch read, for the moments before this
    /// launch's read. Unknown counts as the App Store.
    static func lastKnown(in defaults: UserDefaults) -> AppInstallSource {
        #if DEBUG
        return .xcode
        #else
        #if os(macOS) // MAC: no receipt and a Sparkle feed is a direct download, not the App Store
        if isMacDirectDownload(in: .main) { return .macDirect }
        #endif // MAC:
        return defaults.string(forKey: key).flatMap(AppInstallSource.init(rawValue:)) ?? .appStore
        #endif
    }

    /// Reads the source on every launch, since a TestFlight install can be
    /// replaced by the App Store's and keep its settings. StoreKit keeps the
    /// app transaction, but the first read can need the network: nil until
    /// Apple's signature verifies it, so a later refresh asks again.
    static func detect(defaults: UserDefaults) async -> AppInstallSource? {
        #if DEBUG
        return .xcode
        #else
        #if os(macOS) // MAC: a direct download has no App Store transaction to verify
        if isMacDirectDownload(in: .main) { return .macDirect }
        #endif // MAC:
        guard case .verified(let transaction)? = try? await AppTransaction.shared else { return nil }
        let source: AppInstallSource
        switch transaction.environment {
        case .production: source = .appStore
        case .sandbox: source = .testFlight
        case .xcode: source = .xcode
        default: source = .appStore
        }
        defaults.set(source.rawValue, forKey: key)
        return source
        #endif
    }

    /// Until `detect` verifies: the sandbox receipt tells TestFlight apart,
    /// and anything unknown counts as the App Store, so the worst case is
    /// fewer notices, never more.
    static func unverified() -> AppInstallSource {
        #if DEBUG
        return .xcode
        #else
        #if os(macOS) // MAC:
        if isMacDirectDownload(in: .main) { return .macDirect }
        #endif // MAC:
        return Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt" ? .testFlight : .appStore
        #endif
    }

    #if os(macOS) // MAC: LC-B F3
    /// No App Store receipt and a Sparkle feed (`SUFeedURL`, set in the Mac Info.plist next to the embedded
    /// Sparkle framework) mean a Developer ID download that updates itself.
    static func isMacDirectDownload(receiptExists: Bool, sparkleFeed: String?) -> Bool {
        !receiptExists && !(sparkleFeed ?? "").isEmpty
    }

    static func isMacDirectDownload(in bundle: Bundle) -> Bool {
        let receiptExists = bundle.appStoreReceiptURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        return isMacDirectDownload(receiptExists: receiptExists, sparkleFeed: bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String)
    }
    #endif // MAC:
}
