import Base
import CryptoKit
import Foundation

/// Keeps `ListingCache`'s volumes on disk, with `FolderSizeCache`'s sizes on each: one binary
/// plist per network volume in `<caches root>/listings/`, at most `byteCap` bytes in all, the
/// least recently written file dropped first, except the files of volumes a saved workspace
/// shows (`keep`). Saves are written `writeDelay` after the first unwritten one, so a burst of
/// loads costs one write per volume. A file that doesn't decode to the one stored shape is
/// deleted and logged, and reads as empty. So is a file whose name doesn't have the form
/// `url(for:)` gives, at the next write. See
/// docs/decisions/0039-listing-cache.md, docs/decisions/0043-folder-sizes.md and
/// docs/decisions/0081-restored-network-panes.md.
public actor ListingCacheStore {
    /// The default for `byteCap`.
    public static let defaultByteCap = 50_000_000
    /// How long after the first unwritten save the store writes.
    public static let writeDelay: Duration = .seconds(2)

    private let folder: URL
    private let log: @Sendable (String) -> Void
    private let byteCap: Int
    /// Starts a wait of the given length on the store's clock, taking the deadline at once.
    private let startWait: DeadlineWait.Start
    private let write: @Sendable (Data, URL) throws -> Void
    /// Listings not yet written, by volume.
    private var pending: [VolumeIdentity: [String: ListingCache.Folder]] = [:]
    /// Volumes whose sizes in `sizes` are not yet written.
    private var pendingSizes: Set<VolumeIdentity> = []
    /// The sizes of each volume as last saved or read, so writing a volume's listings needn't
    /// read its file for its sizes.
    private var sizes: [VolumeIdentity: [String: FolderSizeCache.Record]] = [:]
    private var writeScheduled = false
    /// Volumes whose last save encoded to more than `byteCap`, logged once until one fits.
    private var oversized: Set<VolumeIdentity> = []
    /// Volumes whose files `trim` leaves, however far over `byteCap`.
    private var kept: Set<VolumeIdentity> = []

    /// A store in `roots.caches/listings`. `log` gets a line for each file discarded, dropped or
    /// not written. `write` replaces a file's contents; tests pass one that records its calls.
    public init<C: Clock<Duration>>(
        roots: StoreRoots, log: @escaping @Sendable (String) -> Void,
        byteCap: Int = defaultByteCap, clock: C = ContinuousClock(),
        write: @escaping @Sendable (Data, URL) throws -> Void = {
            try AtomicWrite.write($0, to: $1)
        }
    ) {
        folder = roots.caches.appending(path: "listings")
        self.log = log
        self.byteCap = byteCap
        startWait = DeadlineWait.make(on: clock)
        self.write = write
    }

    /// Saves `folders` as everything kept for `volume`, replacing what was saved before.
    ///
    /// - Precondition: `volume` is a network volume; local ones are never kept.
    public func save(_ folders: [String: ListingCache.Folder], for volume: VolumeIdentity) {
        precondition(volume.kind == .network, "local volume \(volume.mountPoint) can't be cached")
        pending[volume] = folders
        scheduleWrite()
    }

    /// Saves `sizes` as every folder size kept for `volume`, replacing what was saved before. The
    /// volume's listings stay as they are.
    ///
    /// - Precondition: `volume` is a network volume; local ones are never kept.
    public func saveSizes(
        _ sizes: [String: FolderSizeCache.Record], for volume: VolumeIdentity
    ) {
        precondition(volume.kind == .network, "local volume \(volume.mountPoint) can't be cached")
        self.sizes[volume] = sizes
        pendingSizes.insert(volume)
        scheduleWrite()
    }

    private func scheduleWrite() {
        guard !writeScheduled else { return }
        writeScheduled = true
        let wait = startWait(Self.writeDelay)
        Task {
            guard await DeadlineWait.reached(wait) else { return }
            flush()
        }
    }

    /// Keeps the files of `volumes`, those of a saved workspace's folders, through `byteCap`,
    /// in place of the volumes kept before.
    public func keep(_ volumes: Set<VolumeIdentity>) {
        kept = volumes
    }

    /// The volume whose file was written for the longest mount point holding `path`, and its
    /// folders, for a path the mount table doesn't place on a volume, as when a share a pane was
    /// restored on isn't mounted. Of the volumes mounted there one after the other, the one
    /// written last. Nil when there is no such file, or when it doesn't decode, which deletes it.
    /// Reads no volume, only the names in the store's folder and the file.
    public func volume(holding path: String) -> (
        volume: VolumeIdentity, folders: [String: ListingCache.Folder]
    )? {
        let files: [(url: URL, modified: Date)]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey]
            ).map { url in
                guard
                    let modified = try url.resourceValues(
                        forKeys: [.contentModificationDateKey]).contentModificationDate
                else { throw MissingAttributes(path: url.path) }
                return (url, modified)
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch {
            log("looking in \(folder.path) for the volume of \(path) failed: \(error)")
            return nil
        }
        for mountPoint in Location(path: path).ancestors.reversed().map(\.folderPath) {
            let prefix = Self.digest(mountPoint) + "-"
            let candidates = files.filter { $0.url.lastPathComponent.hasPrefix(prefix) }
                .sorted { $0.modified > $1.modified }
            for candidate in candidates {
                guard let stored = read(candidate.url) else { continue }
                let volume = VolumeIdentity(
                    device: stored.device, mountPoint: stored.mountPoint, kind: .network,
                    fsType: stored.fsType)
                if sizes[volume] == nil {
                    sizes[volume] = stored.sizes.mapValues(\.record)
                }
                return (volume, pending[volume] ?? stored.folders.mapValues(\.folder))
            }
        }
        return nil
    }

    /// The folders kept for `volume`: the latest save, written or not. Empty when there is no file,
    /// or when the file doesn't decode, which deletes it.
    public func load(_ volume: VolumeIdentity) -> [String: ListingCache.Folder] {
        if let folders = pending[volume] { return folders }
        return read(volume)?.folders.mapValues(\.folder) ?? [:]
    }

    /// The folder sizes kept for `volume`: the latest save, written or not. Empty when there is
    /// no file, or when the file doesn't decode, which deletes it.
    public func loadSizes(_ volume: VolumeIdentity) -> [String: FolderSizeCache.Record] {
        if let sizes = sizes[volume] { return sizes }
        let read = read(volume)?.sizes.mapValues(\.record) ?? [:]
        sizes[volume] = read
        return read
    }

    /// The volume's file, decoded; nil when there is none, or when it doesn't decode, which
    /// deletes it.
    private func read(_ volume: VolumeIdentity) -> StoredVolume? {
        read(url(for: volume))
    }

    /// The file at `url`, decoded; nil when there is none, or when it doesn't decode or holds a
    /// volume whose file it isn't, which deletes it.
    private func read(_ url: URL) -> StoredVolume? {
        do {
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                return nil
            }
            let stored = try PropertyListDecoder().decode(StoredVolume.self, from: data)
            let volume = VolumeIdentity(
                device: stored.device, mountPoint: stored.mountPoint, kind: .network)
            guard self.url(for: volume).lastPathComponent == url.lastPathComponent else {
                throw WrongVolume(device: stored.device, mountPoint: stored.mountPoint)
            }
            return stored
        } catch {
            discard(url, because: error)
            return nil
        }
    }

    /// Writes every save not yet written, then drops the oldest files past `byteCap`. A volume
    /// that alone encodes to more than `byteCap` isn't written; its file, if any, stays as it was.
    public func flush() {
        writeScheduled = false
        let volumes = Set(pending.keys).union(pendingSizes)
        guard !volumes.isEmpty else { return }
        var writes: [VolumeIdentity: StoredVolume] = [:]
        for volume in volumes {
            // A volume saved in one part takes the other from its file.
            writes[volume] = StoredVolume(volume, load(volume), loadSizes(volume))
        }
        pending = [:]
        pendingSizes = []
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            log("creating \(folder.path) failed, so no listing was cached: \(error)")
            return
        }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        for (volume, stored) in writes {
            let url = url(for: volume)
            do {
                let data = try encoder.encode(stored)
                // Written, a file over the cap would only be deleted again by `trim`, and saved
                // and re-encoded at every write.
                guard data.count <= byteCap else {
                    if oversized.insert(volume).inserted {
                        log(
                            "not caching the listings of \(volume.device) on disk: they take"
                                + " \(data.count) bytes, over the \(byteCap)-byte cap")
                    }
                    continue
                }
                oversized.remove(volume)
                try Self.write(data, to: url, with: write)
            } catch {
                log("writing the listings of \(volume.device) to \(url.path) failed: \(error)")
            }
        }
        trim()
    }

    /// Runs `write`, which does file-system I/O; traps on the main thread.
    static func write(
        _ data: Data, to url: URL, with write: (Data, URL) throws -> Void
    ) rethrows {
        dispatchPrecondition(condition: .notOnQueue(.main))
        try write(data, url)
    }

    /// The file `volume`'s folders are kept in. Named by a hash of the mount point, so the files
    /// of a mount point can be found without its device, then a hash of the device and mount
    /// point, which together can be longer than a file name allows.
    nonisolated func url(for volume: VolumeIdentity) -> URL {
        folder.appending(
            path: Self.digest(volume.mountPoint) + "-"
                + Self.digest("\(volume.device)\0\(volume.mountPoint)") + ".plist")
    }

    /// `text`'s SHA-256 in hexadecimal.
    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether `name` has the shape `url(for:)` gives a file's name: two digests joined by `-`.
    private static func isVolumeFileName(_ name: String) -> Bool {
        guard name.hasSuffix(".plist") else { return false }
        let stem = Array(name.utf8.dropLast(".plist".utf8.count))
        let hex = Set("0123456789abcdef".utf8)
        return stem.count == 129 && stem[64] == UInt8(ascii: "-")
            && stem.enumerated().allSatisfy { $0.offset == 64 || hex.contains($0.element) }
    }

    /// Deletes every file whose name doesn't have the form `url(for:)` gives, then the least
    /// recently written files until the folder fits `byteCap`, leaving the files of `kept`
    /// volumes. Each file that can't be deleted, or whose size and date can't be read, is logged
    /// and the rest are still trimmed; a file whose size can't be read isn't counted.
    private func trim() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: keys)
        } catch {
            log("keeping \(folder.path) under \(byteCap) bytes failed: \(error)")
            return
        }
        var files: [(url: URL, size: Int, modified: Date)] = []
        for url in urls {
            do {
                guard Self.isVolumeFileName(url.lastPathComponent) else {
                    try FileManager.default.removeItem(at: url)
                    log("discarded \(url.path), whose name isn't a cached listing file's")
                    continue
                }
                let values = try url.resourceValues(forKeys: Set(keys))
                guard let size = values.fileSize, let modified = values.contentModificationDate
                else { throw MissingAttributes(path: url.path) }
                files.append((url, size, modified))
            } catch {
                log("keeping \(folder.path) under \(byteCap) bytes skipped \(url.path): \(error)")
            }
        }
        files.sort { $0.modified < $1.modified }
        var total = files.reduce(0) { $0 + $1.size }
        let keptNames = Set(kept.map { url(for: $0).lastPathComponent })
        for file in files
        where total > byteCap && !keptNames.contains(file.url.lastPathComponent) {
            do {
                try FileManager.default.removeItem(at: file.url)
                total -= file.size
                log("dropped \(file.url.path) to keep cached listings under \(byteCap) bytes")
            } catch {
                log(
                    "dropping \(file.url.path) to keep cached listings under \(byteCap) bytes"
                        + " failed: \(error)")
            }
        }
    }

    private func discard(_ url: URL, because error: any Error) {
        do {
            try FileManager.default.removeItem(at: url)
            log("discarded \(url.path), which isn't a cached listing file: \(error)")
        } catch let removal {
            log(
                "\(url.path) isn't a cached listing file (\(error)), and deleting it failed: \(removal)"
            )
        }
    }

    struct WrongVolume: Error, CustomStringConvertible {
        let device: String
        let mountPoint: String
        var description: String { "the file holds \(device) at \(mountPoint)" }
    }

    struct MissingAttributes: Error, CustomStringConvertible {
        let path: String
        var description: String { "\(path) has no size or modification date" }
    }
}

// MARK: - Stored shape

// The one shape a file has. Every key must be there and no other may be: a missing or extra key
// fails the decode, so a file of any other shape is discarded rather than read in part. Sort keys
// and folded names aren't stored; `Listing` builds them from the entries.

private struct StoredVolume: Codable {
    let device: String
    let mountPoint: String
    /// `VolumeIdentity.fsType`, part of the volume's identity.
    let fsType: String
    let folders: [String: StoredFolder]
    /// Folder sizes by path. A path needn't have a listing in `folders`, nor the other way round.
    let sizes: [String: StoredSize]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case device, mountPoint, fsType, folders, sizes
    }

    init(
        _ volume: VolumeIdentity, _ folders: [String: ListingCache.Folder],
        _ sizes: [String: FolderSizeCache.Record]
    ) {
        device = volume.device
        mountPoint = volume.mountPoint
        fsType = volume.fsType
        self.folders = folders.mapValues(StoredFolder.init)
        self.sizes = sizes.mapValues(StoredSize.init)
    }

    init(from decoder: any Decoder) throws {
        try requireKeys(Set(CodingKeys.allCases.map(\.stringValue)), in: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        device = try container.decode(String.self, forKey: .device)
        mountPoint = try container.decode(String.self, forKey: .mountPoint)
        fsType = try container.decode(String.self, forKey: .fsType)
        folders = try container.decode([String: StoredFolder].self, forKey: .folders)
        sizes = try container.decode([String: StoredSize].self, forKey: .sizes)
    }
}

/// A `FolderSizeCache.Record`.
private struct StoredSize: Codable {
    let bytes: Int64
    let partial: Bool
    let walkedAt: Date
    let folderModified: Date

    enum CodingKeys: String, CodingKey, CaseIterable {
        case bytes, partial, walkedAt, folderModified
    }

    init(_ record: FolderSizeCache.Record) {
        bytes = record.size.bytes
        partial = record.size.isPartial
        walkedAt = record.size.walkedAt
        folderModified = record.folderModified
    }

    init(from decoder: any Decoder) throws {
        try requireKeys(Set(CodingKeys.allCases.map(\.stringValue)), in: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bytes = try container.decode(Int64.self, forKey: .bytes)
        partial = try container.decode(Bool.self, forKey: .partial)
        walkedAt = try container.decode(Date.self, forKey: .walkedAt)
        folderModified = try container.decode(Date.self, forKey: .folderModified)
    }

    var record: FolderSizeCache.Record {
        FolderSizeCache.Record(
            size: FolderSize(bytes: bytes, isPartial: partial, walkedAt: walkedAt),
            folderModified: folderModified)
    }
}

private struct StoredFolder: Codable {
    let listedAt: Date
    let entries: [StoredEntry]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case listedAt, entries
    }

    init(_ folder: ListingCache.Folder) {
        listedAt = folder.listedAt
        entries = folder.entries.map(StoredEntry.init)
    }

    init(from decoder: any Decoder) throws {
        try requireKeys(Set(CodingKeys.allCases.map(\.stringValue)), in: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        listedAt = try container.decode(Date.self, forKey: .listedAt)
        entries = try container.decode([StoredEntry].self, forKey: .entries)
    }

    var folder: ListingCache.Folder {
        ListingCache.Folder(entries: entries.map(\.entry), listedAt: listedAt)
    }
}

/// A `DirectoryEntry`. `size` is there for a regular file and for nothing else, as the lister
/// reports it, and `tags`, its tags' color labels, for an entry with colored tags and for nothing
/// else, so an untagged entry takes no more room than it did.
private struct StoredEntry: Codable {
    enum FileType: String, Codable {
        case regular, directory, package, symbolicLink, other
    }

    let name: String
    let type: FileType
    let size: Int64?
    let modified: Date
    let hidden: Bool
    let dataless: Bool
    let tags: [Int]?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case name, type, size, modified, hidden, dataless, tags
    }

    init(_ entry: DirectoryEntry) {
        precondition(
            (entry.type == .regular) == (entry.size != nil),
            "\(entry.name) has a size only if it's a regular file")
        name = entry.name
        type =
            switch entry.type {
            case .regular: .regular
            case .directory: .directory
            case .package: .package
            case .symbolicLink: .symbolicLink
            case .other: .other
            // A server's listing isn't cached (docs/decisions/0114-server-location.md).
            case .unmountedShare: preconditionFailure("\(entry.name) is a server's row")
            }
        size = entry.size
        modified = entry.modified
        hidden = entry.isHidden
        dataless = entry.isDataless
        tags = entry.tagLabels.isEmpty ? nil : Array(entry.tagLabels)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(FileType.self, forKey: .type)
        var keys = Set(CodingKeys.allCases.map(\.stringValue))
        if type != .regular { keys.remove(CodingKeys.size.stringValue) }
        if !container.contains(.tags) { keys.remove(CodingKeys.tags.stringValue) }
        try requireKeys(keys, in: decoder)
        name = try container.decode(String.self, forKey: .name)
        size = type == .regular ? try container.decode(Int64.self, forKey: .size) : nil
        modified = try container.decode(Date.self, forKey: .modified)
        hidden = try container.decode(Bool.self, forKey: .hidden)
        dataless = try container.decode(Bool.self, forKey: .dataless)
        if container.contains(.tags) {
            let tags = try container.decode([Int].self, forKey: .tags)
            // As written: at least one color label, each 1 to 7 and once.
            guard !tags.isEmpty, Set(tags).count == tags.count, tags.allSatisfy((1...7).contains)
            else {
                throw DecodingError.dataCorruptedError(
                    forKey: .tags, in: container, debugDescription: "\(tags) aren't tag colors")
            }
            self.tags = tags
        } else {
            tags = nil
        }
    }

    var entry: DirectoryEntry {
        let fileType: DirectoryEntry.FileType =
            switch type {
            case .regular: .regular
            case .directory: .directory
            case .package: .package
            case .symbolicLink: .symbolicLink
            case .other: .other
            }
        return DirectoryEntry(
            name: name, type: fileType, size: size, modified: modified, isHidden: hidden,
            isDataless: dataless, tagLabels: TagLabels(tags ?? []))
    }
}

/// Any key, so a container lists every key the file has, not just the ones a type declares.
private struct AnyKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// Throws unless the dictionary `decoder` reads has exactly `expected` as its keys.
private func requireKeys(_ expected: Set<String>, in decoder: any Decoder) throws {
    let found = Set(try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue))
    guard found == expected else {
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription:
                    "missing keys \(expected.subtracting(found).sorted()),"
                    + " extra keys \(found.subtracting(expected).sorted())"))
    }
}
