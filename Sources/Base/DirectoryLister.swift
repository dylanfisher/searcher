import Darwin
import Foundation

/// Lists one directory, delivering its entries in batches as they're read. Implementations block
/// the calling thread on file-system calls, so callers run them off the main actor.
public protocol Lister: Sendable {
    /// Calls `onBatch` with each batch of entries, in the order the file system returns them, and
    /// returns once the directory is fully listed. An error thrown from `onBatch` stops the
    /// listing and is rethrown; other failures throw `ListingError`.
    func list(_ path: String, onBatch: ([DirectoryEntry]) throws -> Void) throws
}

/// Lists a directory with `getattrlistbulk`, one batch per buffer the call fills. See
/// docs/decisions/0003-enumeration.md.
public struct DirectoryLister: Lister {
    /// Bytes per `getattrlistbulk` call. 256 KB holds about 2,000 entries.
    public let bufferSize: Int

    public init(bufferSize: Int = 256 * 1024) {
        self.bufferSize = bufferSize
    }

    public func list(_ path: String, onBatch: ([DirectoryEntry]) throws -> Void) throws {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if fd < 0 { throw ListingError(path: path, code: errno) }
        defer { close(fd) }

        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr =
            attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_ERROR)
            | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_OBJTYPE)
            | attrgroup_t(ATTR_CMN_MODTIME) | attrgroup_t(ATTR_CMN_FLAGS)
        request.fileattr = attrgroup_t(ATTR_FILE_DATALENGTH)

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }

        while true {
            let count = getattrlistbulk(fd, &request, buffer, bufferSize, 0)
            if count < 0 { throw ListingError(path: path, code: errno) }
            if count == 0 { return }
            var batch: [DirectoryEntry] = []
            batch.reserveCapacity(Int(count))
            var record = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                if let entry = try parse(record, directory: fd, path: path) {
                    batch.append(entry)
                }
                record += Int(record.loadUnaligned(as: UInt32.self))
            }
            try onBatch(batch)
        }
    }

    /// Reads one `getattrlistbulk` record. Attributes are packed in bitmap order and only those
    /// marked returned are present, so each field is read only if its bit is set. Returns nil for
    /// an entry deleted while the directory was being listed.
    private func parse(_ record: UnsafeRawPointer, directory fd: Int32, path: String) throws
        -> DirectoryEntry?
    {
        var field = record + MemoryLayout<UInt32>.size
        let returned = field.loadUnaligned(as: attribute_set_t.self)
        field += MemoryLayout<attribute_set_t>.size
        if returned.commonattr & attrgroup_t(ATTR_CMN_ERROR) != 0 {
            field += MemoryLayout<UInt32>.size
        }

        let nameReference = field.loadUnaligned(as: attrreference_t.self)
        // attr_length counts the trailing NUL.
        let name = String(
            decoding: UnsafeRawBufferPointer(
                start: field + Int(nameReference.attr_dataoffset),
                count: Int(nameReference.attr_length) - 1),
            as: UTF8.self)
        field += MemoryLayout<attrreference_t>.size

        var objectType: fsobj_type_t?
        if returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
            objectType = field.loadUnaligned(as: fsobj_type_t.self)
            field += MemoryLayout<fsobj_type_t>.size
        }
        var modified: timespec?
        if returned.commonattr & attrgroup_t(ATTR_CMN_MODTIME) != 0 {
            modified = field.loadUnaligned(as: timespec.self)
            field += MemoryLayout<timespec>.size
        }
        var flags: UInt32 = 0
        if returned.commonattr & attrgroup_t(ATTR_CMN_FLAGS) != 0 {
            flags = field.loadUnaligned(as: UInt32.self)
            field += MemoryLayout<UInt32>.size
        }
        var dataLength: off_t?
        if returned.fileattr & attrgroup_t(ATTR_FILE_DATALENGTH) != 0 {
            dataLength = field.loadUnaligned(as: off_t.self)
        }

        // A firmlink reports the attributes of its stub on the read-only system volume, such as
        // /Applications at /, where the data volume folder it points to holds the real ones.
        // `fstatat` follows it. An entry the bulk call couldn't fully describe is stat'ed too.
        let isFirmlink = flags & UInt32(SF_FIRMLINK) != 0
        guard !isFirmlink, let objectType, let modified,
            objectType != fsobj_type_t(VREG.rawValue) || dataLength != nil
        else {
            return try stat(name, in: fd, path: path)
        }
        let type = fileType(objectType)
        return DirectoryEntry(
            name: name, type: type, size: type == .regular ? dataLength : nil,
            modified: date(modified))
    }

    private func stat(_ name: String, in fd: Int32, path: String) throws -> DirectoryEntry? {
        var info = Darwin.stat()
        if fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }
            throw ListingError(path: path + "/" + name, code: errno)
        }
        let type: DirectoryEntry.FileType =
            switch info.st_mode & S_IFMT {
            case S_IFREG: .regular
            case S_IFDIR: .directory
            case S_IFLNK: .symbolicLink
            default: .other
            }
        return DirectoryEntry(
            name: name, type: type, size: type == .regular ? info.st_size : nil,
            modified: date(info.st_mtimespec))
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
