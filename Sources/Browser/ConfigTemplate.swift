import Base
import Foundation

/// The config file Open Config File makes when there is none: a note on how the file reads,
/// then every preference in `Settings.preferences`, commented out at its default, so the file
/// sets nothing until a line's `#` is removed.
public enum ConfigTemplate {
    public static let text: String = {
        let header = """
            # Searcher's settings. Each setting is one line: its key, an equals sign, then its
            # value. A "#" starts a comment, to the end of the line.
            #
            # Each setting below is at its default. Remove the "#" in front of one to change it.
            # Searcher reads this file again each time it is saved. A setting changed in the app
            # wins over this file; Settings ▸ General lists those and can set each one back to
            # the value here.
            """
        let settings = Settings.preferences.map { preference in
            "# \(preference.summary)\n# \(preference.name) = \(spelled(preference.defaultValue))"
        }
        return ([header] + settings).joined(separator: "\n\n") + "\n"
    }()

    /// `value` as a line of the template writes it: a choice unquoted, as `appearance = auto`.
    private static func spelled(_ value: Settings.Value) -> String {
        guard case .string(let string) = value, string.allSatisfy(\.isLetter) else {
            return value.description
        }
        return string
    }

    /// Makes the file at `url` from `text`, and its folder when there is none, unless a file is
    /// there. It never writes over one: the write is create-only, so a file an editor saves at
    /// `url` after the check is kept. Call it off the main thread.
    static func create(at url: URL) throws {
        let files = FileManager.default
        if files.fileExists(atPath: url.path) { return }
        // `fileExists` follows a link, so a link to a missing file reads as no file; the
        // create-only write would then fail on the link and the open would open nothing.
        if let target = try? files.destinationOfSymbolicLink(atPath: url.path) {
            throw DanglingLink(target: target)
        }
        try files.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try AtomicWrite.create(Data(text.utf8), at: url)
        } catch POSIXError.EEXIST {
            // Made since the check, by the user: that file is the one to open.
        }
    }

    /// A symbolic link at the config file's path to a file that isn't there.
    struct DanglingLink: LocalizedError {
        let target: String

        var errorDescription: String? {
            "it is a symbolic link to \(target), which doesn't exist"
        }
    }
}
