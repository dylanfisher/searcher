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
        let values = try url.resourceValues(forKeys: [.creationDateKey, .tagNamesKey])
        let lastOpened = MDItemCreate(nil, path as CFString).flatMap {
            MDItemCopyAttribute($0, kMDItemLastUsedDate) as? Date
        }
        return ItemInfo(
            created: values.creationDate, lastOpened: lastOpened, tags: values.tagNames ?? [])
    }
}
