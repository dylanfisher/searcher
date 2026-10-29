import AppKit
import CoreFoundation

/// Which app other apps' Show in Finder opens: the bundle ID in the global `NSFileViewer` key,
/// which AppKit reads on each reveal. The key is read each time, never stored
/// (docs/decisions/0137-default-file-viewer.md). Tests use a stub, so no test changes the
/// machine's file viewer.
@MainActor
protocol FileViewerSetting: AnyObject {
    /// Searcher's bundle ID, or nil when the running app can't be the file viewer, as outside
    /// its app bundle.
    var searcherID: String? { get }
    /// The bundle ID the key names, nil when it isn't set.
    var viewer: String? { get }
    /// Sets the key to `id`, or removes it for nil.
    func setViewer(_ id: String?) throws
    /// The name of the installed app with bundle ID `id`, nil when there is none.
    func appName(of id: String) -> String?
}

/// A change to the global key that macOS didn't save.
struct FileViewerWriteFailed: LocalizedError {
    static let reason = "macOS didn't save the change."

    var errorDescription: String? { Self.reason }
}

/// The global `NSFileViewer` key, read and written through CFPreferences in the global domain.
/// Never through `UserDefaults.standard`, whose argument domain names Finder for Searcher's own
/// reveals (`keepRevealsInFinder`).
@MainActor
public final class GlobalFileViewerSetting: FileViewerSetting {
    nonisolated static let key = "NSFileViewer"
    nonisolated static let finder = "com.apple.finder"

    /// The same test Open at login makes: the key names a bundle ID, which a bare executable
    /// doesn't have.
    var searcherID: String? {
        MainAppLoginItem.runsFromAppBundle ? Bundle.main.bundleIdentifier : nil
    }

    var viewer: String? {
        CFPreferencesCopyValue(
            Self.key as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost) as? String
    }

    func setViewer(_ id: String?) throws {
        CFPreferencesSetValue(
            Self.key as CFString, id as CFString?, kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesAppSynchronize(kCFPreferencesAnyApplication) else {
            throw FileViewerWriteFailed()
        }
    }

    /// Asks Launch Services, which reads no file on this thread; the name is the bundle's file
    /// name, as Finder shows it.
    func appName(of id: String) -> String? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)?
            .deletingPathExtension().lastPathComponent
    }

    /// Has the app's own reveals, which AppKit sends to the app `NSFileViewer` names, go to
    /// Finder whatever the global key names, so Searcher's Reveal in Finder doesn't come back to
    /// it. In memory only: the argument domain wins over the global one and is never written to
    /// disk. Runs at launch, before any window opens.
    public static func keepRevealsInFinder() {
        let defaults = UserDefaults.standard
        let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defaults.setVolatileDomain(
            keepingRevealsInFinder(arguments), forName: UserDefaults.argumentDomain)
    }

    /// `arguments`, an argument domain, with `NSFileViewer` naming Finder.
    nonisolated static func keepingRevealsInFinder(_ arguments: [String: Any]) -> [String: Any] {
        arguments.merging([key: finder]) { _, finder in finder }
    }
}
