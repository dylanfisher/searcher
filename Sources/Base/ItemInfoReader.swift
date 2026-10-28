import CoreServices
import Foundation

/// Reads one item's `ItemInfo`. Implementations block the calling thread on file-system and
/// Spotlight calls, so callers run them off the main actor, on a dispatch queue rather than the
/// cooperative pool: an item on a stalled share blocks the call.
public protocol ItemInfoReading: Sendable {
    /// The info of the item at `path`. Throws when the item can't be read, such as when it is
    /// gone.
    func info(at path: String) throws -> ItemInfo
}

/// Reads the creation date and tags from the item's resource values, and the last-opened date
/// from Spotlight's record of that one item (`MDItem`), which is where Finder's Last opened comes
/// from; no resource value holds it (docs/decisions/0095-preview-metadata.md).
public struct ItemInfoReader: ItemInfoReading {
    public init() {}

    public func info(at path: String) throws -> ItemInfo {
        // A package is a folder on disk, but the trailing slash makes no difference to the read.
        let url = URL(fileURLWithPath: path, isDirectory: false)
        let values = try url.resourceValues(
            forKeys: [.creationDateKey, .tagNamesKey, .labelNumberKey])
        let lastOpened = MDItemCreate(nil, path as CFString).flatMap {
            MDItemCopyAttribute($0, kMDItemLastUsedDate) as? Date
        }
        return ItemInfo(
            created: values.creationDate, lastOpened: lastOpened,
            tags: try tags(at: path, names: values.tagNames ?? [], label: values.labelNumber ?? 0))
    }

    /// The tag entries, with their colors, of the item at `path`, whose tags `NSURL` names
    /// `names` and whose color label is `label`. `NSURL` names a tag for an item that has a
    /// color label and no tags attribute, the label's color's, so that one is given the label's
    /// color. The attribute is read only for an item `NSURL` gives tags, so an item on a volume
    /// without extended attributes isn't read for them
    /// (docs/decisions/0124-tags-in-rows-and-preview.md).
    private func tags(at path: String, names: [String], label: Int) throws -> [String] {
        guard !names.isEmpty else { return [] }
        let entries = try FinderTags.entries(at: path)
        if entries.isEmpty { return names.map { "\($0)\n\(label)" } }
        return entries
    }
}
