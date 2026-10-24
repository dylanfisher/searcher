/// What follows the last dot in `name`, or nothing when that dot is the first or last
/// character: ".bashrc" and "notes." have no extension.
public func pathExtension(of name: String) -> Substring {
    guard let dot = name.utf8.lastIndex(of: UInt8(ascii: ".")), dot != name.startIndex else {
        return ""
    }
    return name[name.index(after: dot)...]
}
