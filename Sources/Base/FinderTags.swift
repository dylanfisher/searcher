import Darwin
import Foundation

/// Reads and writes an item's Finder tags as Finder stores them: the entries of the
/// `com.apple.metadata:_kMDItemUserTags` extended attribute, a binary property list of strings,
/// each a tag's name and, after a newline, its color's label number, "Red\n6" or "Work\n4". A
/// tag without a color may have no number. Entries are written back exactly, so a tag that stays
/// keeps its color, which `NSURL`'s `tagNamesKey` doesn't do: it takes names only and writes
/// each with the color the user's tag list gives it, 0 for a tag that isn't in it. As `NSURL`
/// does, a write also sets the legacy color label in `com.apple.FinderInfo` to the last colored
/// entry's, or clears it. For a symlink, also as `NSURL` does, the tags are the target's, read
/// and written through the link, while the color label goes in the link's own `FinderInfo`,
/// which holds the alias flag a symlink reports (docs/decisions/0121-tag-commands.md).
public enum FinderTags {
    static let attribute = "com.apple.metadata:_kMDItemUserTags"
    static let finderInfo = "com.apple.FinderInfo"
    /// The bits of `FinderInfo`'s `fdFlags`, in its tenth byte, that hold the color label.
    static let colorBits: UInt8 = 0x0E
    /// `kIsAlias`, the high bit of `fdFlags` in its ninth byte, which a symlink's `FinderInfo`
    /// carries once `NSURL` has written it.
    static let aliasBit: UInt8 = 0x80

    /// Writes the tags attribute of the item at a path as the bytes given, or removes it for nil.
    typealias AttributeWriter = (Data?, String) throws(FileOperationError) -> Void
    /// Sets the color label of the item at a path to the number given.
    typealias LabelWriter = (Int, String) throws(FileOperationError) -> Void

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
    /// tags or the attribute is empty. Blocks the calling thread; call it off the main thread.
    ///
    /// - Throws: `FileOperationError` when the item can't be read, or its attribute isn't a list
    ///   of strings (`other`). A volume without extended attributes fails with `ENOTSUP`, which
    ///   is `other`.
    public static func entries(at path: String) throws(FileOperationError) -> [String] {
        preconditionOffMain("FinderTags")
        guard let data = try attributeData(at: path), !data.isEmpty else { return [] }
        guard
            let entries = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String]
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

    /// The color label in `finderInfo`, an item's 32 bytes of `FinderInfo`: 0 for none.
    static func label(finderInfo: UnsafeRawPointer) -> Int {
        Int((finderInfo.load(fromByteOffset: 9, as: UInt8.self) & colorBits) >> 1)
    }

    /// The colors of the tags of the item at `path` for its row, given `label`, the color label
    /// its own `FinderInfo` holds, which a listing reads with the entries. Every write through
    /// `NSURL`, Finder's included, and through `set(entries:at:)` sets that label to the last
    /// colored tag's, so an item with label 0 has no colored tags and isn't read: a folder of
    /// untagged items costs no call beyond its listing. An item with a label and no tags
    /// attribute has the label's color, as `NSURL` reports a tag of that color for it; one whose
    /// tags can't be read, or aren't a list of strings, shows the label's color too, the one
    /// color it is known to have. Blocks the calling thread; call it off the main thread
    /// (docs/decisions/0124-tags-in-rows-and-preview.md).
    public static func rowLabels(at path: String, finderInfoLabel label: Int) -> TagLabels {
        preconditionOffMain("FinderTags")
        guard label != 0 else { return TagLabels() }
        guard let entries = try? self.entries(at: path), !entries.isEmpty else {
            return TagLabels([label])
        }
        return TagLabels(entries.map(self.label(of:)))
    }

    /// Gives the item at `path` the tag entries `entries`, exactly and in that order, in place of
    /// the ones it has, and then the color label; no entries removes the attribute, as Finder
    /// leaves an untagged item. Blocks the calling thread; call it off the main thread.
    ///
    /// Returns nil once both are written. When the label can't be set, the tags are put back as
    /// they were and its error is thrown, so nothing changed. If they can't be put back either,
    /// the tags stay written and the label's error is returned, for the caller to record the
    /// change, so it can still be undone, and report the error.
    ///
    /// - Throws: `FileOperationError` when nothing changed: the tags couldn't be read or
    ///   written, or the label couldn't be set and the tags were put back.
    @discardableResult
    public static func set(entries: [String], at path: String) throws(FileOperationError)
        -> FileOperationError?
    {
        try set(
            entries: entries, at: path, writeAttribute: Self.writeAttribute(_:at:),
            setLabel: Self.setColorLabel(_:at:))
    }

    /// `set(entries:at:)` with the two writes given, so tests can fail either.
    static func set(
        entries: [String], at path: String, writeAttribute: AttributeWriter,
        setLabel: LabelWriter
    ) throws(FileOperationError) -> FileOperationError? {
        preconditionOffMain("FinderTags")
        let before = try attributeData(at: path)
        try writeAttribute(entries.isEmpty ? nil : encoded(entries), path)
        do {
            try setLabel(entries.last { label(of: $0) != 0 }.map(label(of:)) ?? 0, path)
        } catch let labelError {
            do throws(FileOperationError) {
                try writeAttribute(before, path)
            } catch {
                return labelError
            }
            throw labelError
        }
        return nil
    }

    private static func encoded(_ entries: [String]) -> Data {
        do {
            return try PropertyListSerialization.data(
                fromPropertyList: entries, format: .binary, options: 0)
        } catch {
            preconditionFailure("a list of strings didn't encode: \(error)")
        }
    }

    /// The bytes of the item's tags attribute, nil when it has none. A read whose size changed
    /// between asking and reading (`ERANGE`), as when another app wrote the tags meanwhile, is
    /// tried once more.
    static func attributeData(at path: String) throws(FileOperationError) -> Data? {
        var tries = 0
        while true {
            tries += 1
            let size = getxattr(path, attribute, nil, 0, 0, 0)
            if size < 0 {
                if errno == ENOATTR { return nil }
                throw FileOperationError(errno: errno, path: path)
            }
            if size == 0 { return Data() }
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes {
                getxattr(path, attribute, $0.baseAddress, size, 0, 0)
            }
            if read >= 0 { return data.prefix(read) }
            if errno == ENOATTR { return nil }
            if errno == ERANGE, tries < 2 { continue }
            throw FileOperationError(errno: errno, path: path)
        }
    }

    /// Writes `data` as the item's tags attribute, or removes it for nil.
    static func writeAttribute(_ data: Data?, at path: String) throws(FileOperationError) {
        guard let data else {
            guard removexattr(path, attribute, 0) == 0 || errno == ENOATTR else {
                throw FileOperationError(errno: errno, path: path)
            }
            return
        }
        let result = data.withUnsafeBytes {
            setxattr(path, attribute, $0.baseAddress, data.count, 0, 0)
        }
        guard result == 0 else { throw FileOperationError(errno: errno, path: path) }
    }

    /// Sets the legacy color label in the item's own `FinderInfo`, a symlink's included, which
    /// older APIs such as `URLResourceValues.labelNumber` read, keeping its other bytes. A
    /// symlink without one starts from the alias flag it reports, as `NSURL` writes it. A
    /// `FinderInfo` left all zero is removed, as `NSURL` leaves it.
    static func setColorLabel(_ label: Int, at path: String) throws(FileOperationError) {
        var info = [UInt8](repeating: 0, count: 32)
        let read = getxattr(path, finderInfo, &info, info.count, 0, XATTR_NOFOLLOW)
        if read < 0 {
            guard errno == ENOATTR else { throw FileOperationError(errno: errno, path: path) }
            var status = stat()
            guard lstat(path, &status) == 0 else {
                throw FileOperationError(errno: errno, path: path)
            }
            if status.st_mode & S_IFMT == S_IFLNK { info[8] = aliasBit }
        }
        let flags = (info[9] & ~colorBits) | (UInt8(label) << 1 & colorBits)
        guard flags != info[9] else { return }
        info[9] = flags
        if info.allSatisfy({ $0 == 0 }) {
            guard removexattr(path, finderInfo, XATTR_NOFOLLOW) == 0 || errno == ENOATTR else {
                throw FileOperationError(errno: errno, path: path)
            }
            return
        }
        guard setxattr(path, finderInfo, info, info.count, 0, XATTR_NOFOLLOW) == 0 else {
            throw FileOperationError(errno: errno, path: path)
        }
    }
}
