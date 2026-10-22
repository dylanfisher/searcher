import Foundation

/// The folders the app keeps its files in. The app passes `user()`; tests and bench mode pass
/// folders of their own, so they never read or write the user's stores.
public struct StoreRoots: Sendable, Equatable {
    /// Files the app can rebuild, such as cached listings.
    public let caches: URL
    /// Files the app can't rebuild, such as saved workspaces.
    public let applicationSupport: URL

    public init(caches: URL, applicationSupport: URL) {
        self.caches = caches
        self.applicationSupport = applicationSupport
    }

    /// `~/Library/Caches/<bundle ID>` and `~/Library/Application Support/<bundle ID>` for the
    /// running app. Makes no file-system call; the folders are created by whatever writes there.
    public static func user() throws(NoBundleID) -> StoreRoots {
        try user(bundleID: Bundle.main.bundleIdentifier)
    }

    /// The user's roots named by `bundleID`. Throws when it's nil, as it is for a process run
    /// outside its bundle: the stores would otherwise land in a folder no app owns.
    public static func user(bundleID: String?) throws(NoBundleID) -> StoreRoots {
        guard let bundleID else { throw NoBundleID() }
        func folder(_ directory: FileManager.SearchPathDirectory) -> URL {
            FileManager.default.urls(for: directory, in: .userDomainMask)[0]
                .appending(path: bundleID)
        }
        return StoreRoots(
            caches: folder(.cachesDirectory),
            applicationSupport: folder(.applicationSupportDirectory))
    }

    public struct NoBundleID: Error, CustomStringConvertible {
        public var description: String {
            "the main bundle has no bundle ID, so there is no folder to keep the app's files in;"
                + " run the app from its bundle, or pass StoreRoots of a temporary folder"
        }
    }
}
