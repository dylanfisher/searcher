import Base
import Foundation

/// A change to files that `FileOperationQueue` runs. Paths are absolute.
public enum FileOperation: Equatable, Sendable {
    /// Copies each item into the folder under its own name.
    case copy([String], into: String)
    /// Moves each item into the folder under its own name: a rename on one volume, a copy and
    /// then a delete of the source across volumes.
    case move([String], into: String)
    case trash([String])
    /// Gives the item a new name in the same folder.
    case rename(String, to: String)
    /// Makes "untitled folder", or the first free "untitled folder N", in the folder.
    case newFolder(in: String)
    /// Copies each item beside itself with Finder's duplicate name, "name copy.ext".
    case duplicate([String])
    /// Deletes each item without the Trash. Issued only after the user answered a
    /// delete-immediately question.
    case deleteImmediately([String])
    /// Files a drop promised into the folder: the source app writes them and a `move` puts them
    /// in place. `name` is the file's when one file is meant, and `app` the app the drop came
    /// from when known. The queue never runs it; it only shows one that failed
    /// (`FileOperationQueue.report`).
    case receive(name: String?, app: String?, into: String)

    /// The paths it reads without changing, as known before it runs.
    var reads: [String] {
        switch self {
        case .copy(let sources, _), .duplicate(let sources): sources
        case .move, .trash, .rename, .newFolder, .deleteImmediately, .receive: []
        }
    }

    /// The paths it creates, moves or removes, as known before it runs. A duplicate's and a new
    /// folder's names are picked when they run, so they aren't here.
    var changes: [String] {
        switch self {
        case .copy(let sources, let folder):
            sources.map { Self.path(of: $0, in: folder) }
        case .move(let sources, let folder):
            sources + sources.map { Self.path(of: $0, in: folder) }
        case .trash(let paths), .deleteImmediately(let paths):
            paths
        case .rename(let path, let name):
            [path, Self.renamed(path, to: name)]
        case .newFolder, .duplicate, .receive:
            []
        }
    }

    /// `path` as the refusal checks compare it: without case and with Unicode normalized, as
    /// APFS compares names by default, and without trailing slashes. On a case-sensitive volume
    /// two different items can compare equal, which only refuses more.
    public static func comparable(_ path: String) -> String {
        var path = path.folding(options: .caseInsensitive, locale: nil)
            .precomposedStringWithCanonicalMapping
        while path.utf8.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// The first of `sources` that `folder` is or is inside, compared as `comparable` gives
    /// them: a copy or move of it into `folder` would go into itself. Nil when there is none.
    public static func source(holding folder: String, among sources: [String]) -> String? {
        let target = comparable(folder)
        return sources.first { isPath(target, atOrUnder: comparable($0)) }
    }

    /// Where `source` goes when it moves or is copied into `folder`.
    static func path(of source: String, in folder: String) -> String {
        (folder.hasSuffix("/") ? folder : folder + "/") + (source as NSString).lastPathComponent
    }

    /// The path `path` has once renamed to `name`.
    static func renamed(_ path: String, to name: String) -> String {
        (path as NSString).deletingLastPathComponent + "/" + name
    }
}
