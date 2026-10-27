import Foundation

/// A fresh folder under the temporary directory and a `UserDefaults` suite stored inside it, for
/// a process that must not read or write the user's own stores, such as the UI bench. The owner
/// calls `remove()` before it exits.
///
/// The suite is named by an absolute path, which cfprefsd stores at that path plus `.plist`, so
/// removing the folder removes it. A suite named by a plain name lives in ~/Library/Preferences,
/// where cfprefsd writes an emptied domain's plist back even after it is deleted.
public struct TempRoot: Sendable {
    public let folder: URL
    /// `<folder>/preferences`, so the suite's file is `<folder>/preferences.plist`.
    public let suiteName: String

    /// Creates `<prefix>-<UUID>` under the temporary directory. Call it off the main thread.
    public init(prefix: String) throws {
        preconditionOffMain("TempRoot")
        folder = FileManager.default.temporaryDirectory
            .appending(path: "\(prefix)-\(UUID().uuidString)")
        suiteName = folder.appending(path: "preferences").path
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    }

    /// Removes every root made with `prefix`, for an owner that was killed before it could call
    /// `remove()`. Call it off the main thread.
    public static func removeAll(prefix: String) throws {
        preconditionOffMain("TempRoot")
        // An empty prefix would match every `-*` in the temporary directory.
        precondition(
            !prefix.isEmpty && !prefix.contains("/"),
            "TempRoot.removeAll needs a prefix that is one non-empty name, got \(prefix)")
        let temporary = FileManager.default.temporaryDirectory
        for name in try FileManager.default.contentsOfDirectory(atPath: temporary.path)
        where name.hasPrefix(prefix + "-") {
            try FileManager.default.removeItem(at: temporary.appending(path: name))
        }
    }

    /// Removes the folder with everything in it, the suite's file among them. Call it off the
    /// main thread.
    public func remove() throws {
        preconditionOffMain("TempRoot")
        try FileManager.default.removeItem(at: folder)
    }
}
