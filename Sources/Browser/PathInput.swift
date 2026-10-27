import Base
import Foundation

/// Turns a path the user typed into a folder: `~` and `~/…` start at the home folder, a path not
/// starting with `/` starts at the pane's folder, or at `/Volumes` for a server, and `.` and `..`
/// are taken apart by their text, with `..` at `/` staying there. It makes no file-system call,
/// so a symbolic link in the path isn't resolved first and the result may not exist.
public enum PathInput {
    /// The folder `text` names, or nil when it is blank. `~user` isn't expanded; it's a name like
    /// any other.
    public static func location(for text: String, in folder: Location, home: String) -> Location? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let absolute: String
        if text == "~" || text.hasPrefix("~/") {
            absolute = home + "/" + text.dropFirst()
        } else if text.hasPrefix("/") {
            absolute = text
        } else {
            switch folder {
            case .folder(let path):
                absolute = path + "/" + text
            case .server:
                // A server's shares are its folders in /Volumes (0114-server-location.md).
                absolute = Server.sharesFolder.folderPath + "/" + text
            }
        }
        var components: [Substring] = []
        for component in pathComponents(absolute) {
            switch component {
            case ".": continue
            case "..": _ = components.popLast()
            default: components.append(component)
            }
        }
        return Location(path: "/" + components.joined(separator: "/"))
    }
}
