import Darwin
import Foundation

/// Lists one directory, delivering its entries in batches as they're read. Implementations block
/// the calling thread on file-system calls, so callers run them off the main actor.
public protocol Lister: Sendable {
    /// Calls `onBatch` with each batch of entries, in the order the file system returns them, and
    /// returns once the directory is fully listed. An error thrown from `onBatch` stops the
    /// listing and is rethrown; other failures throw `ListingError`.
    func list(_ path: String, onBatch: ([DirectoryEntry]) throws -> Void) throws

    /// Lists `path` as `list(_:onBatch:)` does, and returns how many entries it left out because
    /// their names aren't valid UTF-8 (docs/decisions/0117-unreadable-names.md).
    func listCountingUnreadableNames(
        _ path: String, onBatch: ([DirectoryEntry]) throws -> Void
    ) throws -> Int
}

extension Lister {
    /// A lister that doesn't read names from the file system has every name as a `String`, so it
    /// leaves none out.
    public func listCountingUnreadableNames(
        _ path: String, onBatch: ([DirectoryEntry]) throws -> Void
    ) throws -> Int {
        try list(path, onBatch: onBatch)
        return 0
    }
}

/// Lists a directory with `getattrlistbulk`, one batch per buffer the call fills. See
/// docs/decisions/0003-enumeration.md. An entry whose name isn't valid UTF-8 is left out: a
/// `String` can't hold its name, so no path built from the name would reach it
/// (docs/decisions/0117-unreadable-names.md).
public struct DirectoryLister: Lister {
    /// Bytes per `getattrlistbulk` call. 256 KB holds about 2,000 entries.
    public let bufferSize: Int
    /// Reads the Finder info of the item at a path, not following a symlink, into the buffer
    /// given, as `getattrlist` replies: its length, then the 32 bytes. Returns 0, or the `errno`
    /// it failed with. Tests fail it.
    let readFinderInfo: @Sendable (String, UnsafeMutableRawBufferPointer) -> Int32

    public init(bufferSize: Int = 256 * 1024) {
        self.init(bufferSize: bufferSize, readFinderInfo: Self.getFinderInfo)
    }

    init(
        bufferSize: Int = 256 * 1024,
        readFinderInfo: @escaping @Sendable (String, UnsafeMutableRawBufferPointer) -> Int32
    ) {
        self.bufferSize = bufferSize
        self.readFinderInfo = readFinderInfo
    }

    public func list(_ path: String, onBatch: ([DirectoryEntry]) throws -> Void) throws {
        _ = try listCountingUnreadableNames(path, onBatch: onBatch)
    }

    public func listCountingUnreadableNames(
        _ path: String, onBatch: ([DirectoryEntry]) throws -> Void
    ) throws -> Int {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if fd < 0 { throw ListingError(path: path, code: errno) }
        defer { close(fd) }
        return try read(fd, path: path, skipsMountPoints: false, onBatch: onBatch)
    }

    /// Lists `path` as `list(_:onBatch:)` does, leaving out folders that another volume is
    /// mounted on, if the folder is on `device`; returns whether it was. A folder on another
    /// device is opened but not read. The device is read from the open folder, so the path is
    /// looked up once. A walk uses it to stay on one volume: `/System/Volumes/Data` shares its
    /// device with `/`, so only the mount status keeps a walk of `/System` out of it.
    public func listWithoutMountPoints(
        _ path: String, ifOnDevice device: dev_t, onBatch: ([DirectoryEntry]) throws -> Void
    ) throws -> Bool {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if fd < 0 { throw ListingError(path: path, code: errno) }
        defer { close(fd) }
        var info = Darwin.stat()
        if fstat(fd, &info) != 0 { throw ListingError(path: path, code: errno) }
        guard info.st_dev == device else { return false }
        _ = try read(fd, path: path, skipsMountPoints: true, onBatch: onBatch)
        return true
    }

    /// The device holding `path`, following a symlink, as
    /// `listWithoutMountPoints(_:ifOnDevice:onBatch:)` compares it.
    public func device(of path: String) throws -> dev_t {
        var info = Darwin.stat()
        if fstatat(AT_FDCWD, path, &info, 0) != 0 { throw ListingError(path: path, code: errno) }
        return info.st_dev
    }

    /// Reads the open folder `fd` to its end and returns how many entries had unreadable names.
    private func read(
        _ fd: Int32, path: String, skipsMountPoints: Bool,
        onBatch: ([DirectoryEntry]) throws -> Void
    ) throws -> Int {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr =
            attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_ERROR)
            | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_OBJTYPE)
            | attrgroup_t(ATTR_CMN_MODTIME) | attrgroup_t(ATTR_CMN_FNDRINFO)
            | attrgroup_t(ATTR_CMN_FLAGS)
        if skipsMountPoints { request.dirattr = attrgroup_t(ATTR_DIR_MOUNTSTATUS) }
        request.fileattr = attrgroup_t(ATTR_FILE_DATALENGTH)

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }

        var unreadableNames = 0
        while true {
            let count = getattrlistbulk(fd, &request, buffer, bufferSize, 0)
            if count < 0 { throw ListingError(path: path, code: errno) }
            if count == 0 { return unreadableNames }
            var batch: [DirectoryEntry] = []
            batch.reserveCapacity(Int(count))
            var offset = 0
            for _ in 0..<count {
                let rest = UnsafeRawBufferPointer(
                    start: buffer + offset, count: bufferSize - offset)
                switch try parseRecord(rest, directory: fd, path: path) {
                case .entry(let entry, let isMountPoint):
                    if !(skipsMountPoints && isMountPoint) { batch.append(entry) }
                case .removed: break
                case .unreadableName: unreadableNames += 1
                }
                // parseRecord checked the length lies within the buffer.
                offset += Int(rest.loadUnaligned(as: UInt32.self))
            }
            try onBatch(batch)
        }
    }

    /// The entry named `name` in the directory at `path`, described as a listing describes it, or
    /// nil if there is none. Change watching uses it to patch one entry without a listing.
    public func entry(named name: String, inDirectory path: String) throws -> DirectoryEntry? {
        var info = Darwin.stat()
        if lstat(join(path, name), &info) != 0 {
            if errno == ENOENT { return nil }
            throw ListingError(path: join(path, name), code: errno)
        }
        return try entry(named: name, at: join(path, name), info: info)
    }

    /// Whether what `path` names, following links, is a package, by the target's own name and
    /// Finder info, as a listing of its folder would report it. False when the target isn't a
    /// folder or can't be read: the listing of `path` that a caller makes next reports why.
    /// Blocks on the file system, so call it off the main thread.
    public static func isPackage(followingLinksAt path: String) -> Bool {
        guard let target = resolvedPath(path) else { return false }
        var info = Darwin.stat()
        guard lstat(target, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
            let name = target.split(separator: "/").last
        else { return false }
        do {
            return try PackageRule.isPackage(folderAt: target, named: String(name)) == true
        } catch {
            return false
        }
    }

    /// What one `getattrlistbulk` record describes.
    enum Record {
        /// An entry, with whether it is a folder another volume is mounted on. That is known only
        /// when the record has `ATTR_DIR_MOUNTSTATUS`, which `listWithoutMountPoints` asks for.
        case entry(DirectoryEntry, isMountPoint: Bool)
        /// An entry deleted while the directory was being listed.
        case removed
        /// An entry whose name isn't valid UTF-8, which the listing leaves out.
        case unreadableName
    }

    /// Reads the record at the start of `buffer`, which runs to the end of the bytes
    /// `getattrlistbulk` was given. Attributes are packed in bitmap order and only those marked
    /// returned are present, so each field is read only if its bit is set. A record that runs
    /// past `buffer`, or whose fields or name run past the record, throws `EBADMSG` rather than
    /// reading outside it.
    func parseRecord(_ buffer: UnsafeRawBufferPointer, directory fd: Int32, path: String) throws
        -> Record
    {
        let malformed = ListingError(path: path, code: EBADMSG)
        guard let record = buffer.baseAddress, buffer.count >= MemoryLayout<UInt32>.size,
            Int(record.loadUnaligned(as: UInt32.self)) <= buffer.count
        else { throw malformed }
        var fields = Fields(
            next: record + MemoryLayout<UInt32>.size,
            end: record + Int(record.loadUnaligned(as: UInt32.self)), malformed: malformed)
        let returned = try fields.take(attribute_set_t.self)
        if returned.commonattr & attrgroup_t(ATTR_CMN_ERROR) != 0 {
            _ = try fields.take(UInt32.self)
        }

        guard returned.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0 else { throw malformed }
        let nameField = fields.next
        let nameReference = try fields.take(attrreference_t.self)
        // The offset counts from the reference, and the length counts the trailing NUL.
        let nameStart = nameField + Int(nameReference.attr_dataoffset)
        let nameLength = Int(nameReference.attr_length)
        guard nameLength >= 1, nameStart >= record, fields.end - nameStart >= nameLength,
            nameStart.load(fromByteOffset: nameLength - 1, as: UInt8.self) == 0
        else { throw malformed }
        // Validating costs what `String(decoding:)`'s repair did: one pass over the bytes, with
        // a fast path for ASCII.
        guard let name = String(validatingCString: nameStart.assumingMemoryBound(to: CChar.self))
        else { return .unreadableName }
        // A NUL before the end would make the name another, shorter one.
        guard name.utf8.count == nameLength - 1 else { throw malformed }

        var objectType: fsobj_type_t?
        if returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
            objectType = try fields.take(fsobj_type_t.self)
        }
        var modified: timespec?
        if returned.commonattr & attrgroup_t(ATTR_CMN_MODTIME) != 0 {
            modified = try fields.take(timespec.self)
        }
        // The Finder info's bundle bit makes a folder a package whatever its name, and its color
        // label says whether the item has colored tags to read.
        var hasBundleBit = false
        var label = 0
        if returned.commonattr & attrgroup_t(ATTR_CMN_FNDRINFO) != 0 {
            let finderInfo = fields.next
            try fields.skip(PackageRule.finderInfoSize)
            hasBundleBit = PackageRule.hasBundleBit(finderInfo)
            label = FinderTags.label(finderInfo: finderInfo)
        }
        // A file system without flags leaves them out, and XNU's `stat` reports 0 for it too, so
        // stat'ing the entry would cost a call per entry for the same answer. APFS, HFS+, FAT32,
        // exFAT, SMB and devfs all return them.
        var flags: UInt32 = 0
        if returned.commonattr & attrgroup_t(ATTR_CMN_FLAGS) != 0 {
            flags = try fields.take(UInt32.self)
        }
        var isMountPoint = false
        if returned.dirattr & attrgroup_t(ATTR_DIR_MOUNTSTATUS) != 0 {
            isMountPoint = try fields.take(UInt32.self) & UInt32(DIR_MNTSTATUS_MNTPOINT) != 0
        }
        var dataLength: off_t?
        if returned.fileattr & attrgroup_t(ATTR_FILE_DATALENGTH) != 0 {
            dataLength = try fields.take(off_t.self)
        }

        // A firmlink reports the attributes of its stub on the read-only system volume, such as
        // /Applications at /, where the data volume folder it points to holds the real ones.
        // `fstatat` follows it. An entry the bulk call couldn't fully describe is stat'ed too.
        guard flags & UInt32(SF_FIRMLINK) == 0, let objectType, let modified,
            objectType != fsobj_type_t(VREG.rawValue) || dataLength != nil
        else {
            guard let entry = try stat(name, in: fd, path: path) else { return .removed }
            return .entry(entry, isMountPoint: isMountPoint)
        }
        var type = fileType(objectType)
        if type == .directory, hasBundleBit || PackageRule.isPackage(named: name) {
            type = .package
        }
        let entry = DirectoryEntry(
            name: name, type: type, size: type == .regular ? dataLength : nil,
            modified: date(modified), isHidden: flags & UInt32(UF_HIDDEN) != 0,
            isDataless: flags & UInt32(SF_DATALESS) != 0,
            tagLabels: label == 0
                ? TagLabels() : FinderTags.rowLabels(at: join(path, name), finderInfoLabel: label))
        return .entry(entry, isMountPoint: isMountPoint)
    }

    /// The fixed-size fields of one record, read in order, each checked to end within the record.
    private struct Fields {
        private(set) var next: UnsafeRawPointer
        let end: UnsafeRawPointer
        let malformed: ListingError

        /// Reads the next field as a `T`.
        mutating func take<T>(_ type: T.Type) throws -> T {
            let start = next
            try skip(MemoryLayout<T>.size)
            return start.loadUnaligned(as: T.self)
        }

        /// Moves past the next `size` bytes.
        mutating func skip(_ size: Int) throws {
            guard end - next >= size else { throw malformed }
            next += size
        }
    }

    private func stat(_ name: String, in fd: Int32, path: String) throws -> DirectoryEntry? {
        var info = Darwin.stat()
        if fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }
            throw ListingError(path: join(path, name), code: errno)
        }
        return try entry(named: name, at: join(path, name), info: info)
    }

    /// The entry `info` describes, named `name`, at `path`; nil if it was removed since. Its
    /// Finder info is read once, for its color label and, for a folder whose name doesn't say it
    /// is a package, the bundle bit.
    private func entry(named name: String, at path: String, info: Darwin.stat) throws
        -> DirectoryEntry?
    {
        guard let finderInfo = try finderInfo(at: path) else { return nil }
        let type: DirectoryEntry.FileType
        switch info.st_mode & S_IFMT {
        case S_IFREG: type = .regular
        case S_IFDIR:
            let isPackage =
                PackageRule.isPackage(named: name)
                || finderInfo.withUnsafeBytes { PackageRule.hasBundleBit($0.baseAddress!) }
            type = isPackage ? .package : .directory
        case S_IFLNK: type = .symbolicLink
        default: type = .other
        }
        let label = finderInfo.withUnsafeBytes { FinderTags.label(finderInfo: $0.baseAddress!) }
        return DirectoryEntry(
            name: name, type: type, size: type == .regular ? info.st_size : nil,
            modified: date(info.st_mtimespec), isHidden: info.st_flags & UInt32(UF_HIDDEN) != 0,
            isDataless: info.st_flags & UInt32(SF_DATALESS) != 0,
            tagLabels: FinderTags.rowLabels(at: path, finderInfoLabel: label))
    }

    /// The 32 bytes of Finder info of the item at `path`, not following a symlink, as a listing
    /// reads them; nil when the item is gone. A volume that refuses the read with `ENOTSUP` or
    /// `EINVAL` has none to give, so the entry reads as one with all zeros, no color label and
    /// no bundle bit, rather than failing over its tags
    /// (docs/decisions/0124-tags-in-rows-and-preview.md).
    private func finderInfo(at path: String) throws -> [UInt8]? {
        // The reply is its UInt32 length, then the Finder info.
        var reply = [UInt8](
            repeating: 0, count: MemoryLayout<UInt32>.size + PackageRule.finderInfoSize)
        let code = reply.withUnsafeMutableBytes { readFinderInfo(path, $0) }
        switch code {
        case 0: return Array(reply.dropFirst(MemoryLayout<UInt32>.size))
        case ENOENT: return nil
        case ENOTSUP, EINVAL: return [UInt8](repeating: 0, count: PackageRule.finderInfoSize)
        default: throw ListingError(path: path, code: code)
        }
    }

    /// `readFinderInfo` through `getattrlist`.
    private static func getFinderInfo(_ path: String, into reply: UnsafeMutableRawBufferPointer)
        -> Int32
    {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_FNDRINFO)
        let status = getattrlist(
            path, &request, reply.baseAddress, reply.count, UInt32(FSOPT_NOFOLLOW))
        return status == 0 ? 0 : errno
    }

    private func fileType(_ objectType: fsobj_type_t) -> DirectoryEntry.FileType {
        switch objectType {
        case fsobj_type_t(VREG.rawValue): .regular
        case fsobj_type_t(VDIR.rawValue): .directory
        case fsobj_type_t(VLNK.rawValue): .symbolicLink
        default: .other
        }
    }

    /// Builds the date the way Foundation does from a `timespec`, so it compares equal to
    /// `FileManager`'s modification date rather than differing in the last bit.
    private func date(_ time: timespec) -> Date {
        Date(
            timeIntervalSinceReferenceDate: Double(time.tv_sec)
                - Date.timeIntervalBetween1970AndReferenceDate + 1e-9 * Double(time.tv_nsec))
    }
}
