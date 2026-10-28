import Darwin
import Foundation

/// Reads and writes an item's Finder tags as Finder stores them: the entries of the
/// `com.apple.metadata:_kMDItemUserTags` extended attribute, a binary property list of strings,
/// each a tag's name and, after a newline, its color's label number, "Red\n6" or "Work\n4". A
/// tag without a color may have no number. Entries are written back exactly, so a tag that stays
/// keeps its color, which `NSURL`'s `tagNamesKey` doesn't do: it takes names only and writes
/// each with the color the user's tag list gives it, 0 for a tag that isn't in it. As `NSURL`
/// does, a write also sets the legacy color label in `com.apple.FinderInfo` to the last colored
/// entry's, or clears it. An item that is a symlink has the tags of the item it points to, as
/// with `NSURL` (docs/decisions/0121-tag-commands.md).
public enum FinderTags {
    static let attribute = "com.apple.metadata:_kMDItemUserTags"
    static let finderInfo = "com.apple.FinderInfo"
    /// The bits of `FinderInfo`'s `fdFlags`, in its tenth byte, that hold the color label.
    static let colorBits: UInt8 = 0x0E

    /// The name of `entry`, before its newline.
    public static func name(of entry: String) -> String {
        entry.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first
            .map(String.init) ?? entry
    }

    /// The color label number of `entry`, 1 to 7, or 0 for a tag without a color.
    public static func label(of entry: String) -> Int {
        let parts = entry.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let label = Int(parts[1]), (0...7).contains(label) else {
            return 0
        }
        return label
    }

    /// The entries of the item at `path`, in the order Finder lists them; none when it has no
    /// tags. Blocks the calling thread; call it off the main thread.
    ///
    /// - Throws: `FileOperationError` when the item can't be read, or its attribute isn't a list
    ///   of strings (`other`).
    public static func entries(at path: String) throws(FileOperationError) -> [String] {
        preconditionOffMain("FinderTags")
        let size = getxattr(path, attribute, nil, 0, 0, 0)
        if size < 0 {
            if errno == ENOATTR { return [] }
            throw FileOperationError(errno: errno, path: path)
        }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes {
            getxattr(path, attribute, $0.baseAddress, size, 0, 0)
        }
        if read < 0 {
            if errno == ENOATTR { return [] }
            throw FileOperationError(errno: errno, path: path)
        }
        guard
            let entries = try? PropertyListSerialization.propertyList(
                from: data.prefix(read), format: nil) as? [String]
        else {
            throw FileOperationError(reason: .other, path: path, errno: nil)
        }
        return entries
    }

    /// The names of the item's tags, in order. Blocks the calling thread; call it off the main
    /// thread.
    public static func names(at path: String) throws(FileOperationError) -> [String] {
        try entries(at: path).map(name(of:))
    }

    /// Gives the item at `path` the tag entries `entries`, exactly and in that order, in place of
    /// the ones it has; none removes the attribute, as Finder leaves an untagged item. Blocks the
    /// calling thread; call it off the main thread.
    public static func set(entries: [String], at path: String) throws(FileOperationError) {
        preconditionOffMain("FinderTags")
        if entries.isEmpty {
            guard removexattr(path, attribute, 0) == 0 || errno == ENOATTR else {
                throw FileOperationError(errno: errno, path: path)
            }
        } else {
            let data: Data
            do {
                data = try PropertyListSerialization.data(
                    fromPropertyList: entries, format: .binary, options: 0)
            } catch {
                preconditionFailure("a list of strings didn't encode: \(error)")
            }
            let result = data.withUnsafeBytes {
                setxattr(path, attribute, $0.baseAddress, data.count, 0, 0)
            }
            guard result == 0 else { throw FileOperationError(errno: errno, path: path) }
        }
        try setColorLabel(entries.last { label(of: $0) != 0 }.map(label(of:)) ?? 0, at: path)
    }

    /// Sets the legacy color label in the item's `FinderInfo`, which older APIs such as
    /// `URLResourceValues.labelNumber` read, keeping its other bytes. A `FinderInfo` left all
    /// zero is removed, as `NSURL` leaves it.
    private static func setColorLabel(_ label: Int, at path: String) throws(FileOperationError) {
        var info = [UInt8](repeating: 0, count: 32)
        let read = getxattr(path, finderInfo, &info, info.count, 0, 0)
        if read < 0, errno != ENOATTR { throw FileOperationError(errno: errno, path: path) }
        let flags = (info[9] & ~colorBits) | (UInt8(label) << 1 & colorBits)
        guard flags != info[9] else { return }
        info[9] = flags
        if info.allSatisfy({ $0 == 0 }) {
            guard removexattr(path, finderInfo, 0) == 0 || errno == ENOATTR else {
                throw FileOperationError(errno: errno, path: path)
            }
            return
        }
        guard setxattr(path, finderInfo, info, info.count, 0, 0) == 0 else {
            throw FileOperationError(errno: errno, path: path)
        }
    }
}
