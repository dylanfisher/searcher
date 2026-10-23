/// Whether `path` is `folder` or inside it, by the paths' text. Both are absolute; a folder
/// whose name only starts with the same text, such as `/a/bc` for `/a/b`, isn't inside it.
public func isPath(_ path: String, atOrUnder folder: String) -> Bool {
    path == folder || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
}
