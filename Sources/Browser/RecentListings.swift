import Base
import Foundation

/// The listings panes last showed of folders on local volumes, in memory only, so a pane or
/// column that comes back to one shows its rows in the same main-actor turn that moves it, as
/// cached rows, while the folder is listed again. Holds at most `folderCap` folders and
/// `entryCap` entries; past either, the least recently used folders go. A folder with more than
/// `entryCap` entries isn't kept. A volume mounting or unmounting drops the folders at or under
/// its mount point (`VolumeEvents`), since another volume there holds other folders. See docs/decisions/0109-recent-local-listings.md.
@MainActor
public final class RecentListings {
    /// A kept listing and when it was listed.
    public struct Kept: Sendable {
        public let listing: Listing
        public let listedAt: Date
    }

    /// Folders kept, unless the owner passes another number. Back and Forward, and the columns of
    /// a trail, revisit a few dozen folders; lookups and drops by path don't grow with it.
    public static let defaultFolderCap = 100
    /// Entries kept across every folder, unless the owner passes another number. Half of W2: a
    /// `Listing` costs at most B9's 60 MB per 100k entries, so this holds at most 30 MB beyond
    /// the listings panes show, which share their storage with the kept ones.
    public static let defaultEntryCap = 50_000

    private let folderCap: Int
    private let entryCap: Int
    private var folders: [String: (kept: Kept, lastUse: Int)] = [:]
    private var useCount = 0
    /// Entries held across `folders`.
    public private(set) var entryCount = 0

    public init(folderCap: Int = defaultFolderCap, entryCap: Int = defaultEntryCap) {
        precondition(folderCap > 0, "recent listings need room for a folder, got \(folderCap)")
        precondition(entryCap > 0, "recent listings need room for an entry, got \(entryCap)")
        self.folderCap = folderCap
        self.entryCap = entryCap
        VolumeEvents.add(self)
    }

    /// The folders kept.
    public var count: Int { folders.count }

    /// The listing kept for `path`, marked most recently used; nil if none is kept.
    public func listing(at path: String) -> Kept? {
        guard let found = folders[path] else { return nil }
        useCount += 1
        folders[path] = (found.kept, useCount)
        return found.kept
    }

    /// Keeps `listing` as `path`'s, replacing any it had, and drops the least recently used
    /// folders past either cap. A listing past `entryCap` alone drops the one kept for `path`.
    public func keep(_ listing: Listing, listedAt: Date, at path: String) {
        drop(path)
        guard listing.entries.count <= entryCap else { return }
        useCount += 1
        folders[path] = (Kept(listing: listing, listedAt: listedAt), useCount)
        entryCount += listing.entries.count
        while folders.count > folderCap || entryCount > entryCap {
            guard let oldest = folders.min(by: { $0.value.lastUse < $1.value.lastUse })?.key
            else { break }
            drop(oldest)
        }
    }

    /// Drops the listing kept for `path`, if any.
    public func drop(_ path: String) {
        guard let dropped = folders.removeValue(forKey: path) else { return }
        entryCount -= dropped.kept.listing.entries.count
    }

    /// Drops the listings kept for `path` and every folder under it, as when the folder is gone.
    public func drop(under path: String) {
        for kept in folders.keys where isPath(kept, atOrUnder: path) {
            drop(kept)
        }
    }
}
