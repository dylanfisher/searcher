import Darwin
import Foundation
import UniformTypeIdentifiers

/// Finder's rule for which folders are packages: the folder's extension names a type that
/// conforms to `com.apple.package`, or its Finder info has the bundle bit. It agrees with
/// `URLResourceValues.isPackage` without asking Launch Services per folder
/// (docs/decisions/0093-packages-are-files.md).
enum PackageRule {
    /// The size of `ATTR_CMN_FNDRINFO`.
    static let finderInfoSize = 32

    /// Whether a folder with `finderInfo`, its 32 bytes of Finder info, has the bundle bit. A
    /// folder's Finder flags are the big-endian UInt16 at offset 8, and `kHasBundle` is 0x2000.
    static func hasBundleBit(_ finderInfo: UnsafeRawPointer) -> Bool {
        UInt16(bigEndian: (finderInfo + 8).loadUnaligned(as: UInt16.self)) & 0x2000 != 0
    }

    /// Whether a folder named `name` is a package by its extension. Each extension is looked up
    /// once per process, since a miss asks Launch Services.
    static func isPackage(named name: String) -> Bool {
        let suffix = pathExtension(of: name)
        if suffix.isEmpty { return false }
        return cache.isPackage(String(suffix))
    }

    /// Whether the folder at `path` is a package, reading its Finder info only when its name
    /// doesn't say; nil when the folder is gone by then. For a folder read alone; a listing reads
    /// the Finder info with the entries.
    static func isPackage(folderAt path: String, named name: String) throws -> Bool? {
        if isPackage(named: name) { return true }
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_FNDRINFO)
        // The reply is its UInt32 length, then the Finder info.
        var reply = [UInt8](repeating: 0, count: MemoryLayout<UInt32>.size + finderInfoSize)
        let status = reply.withUnsafeMutableBytes { buffer in
            getattrlist(path, &request, buffer.baseAddress, buffer.count, UInt32(FSOPT_NOFOLLOW))
        }
        if status != 0 {
            if errno == ENOENT { return nil }
            throw ListingError(path: path, code: errno)
        }
        return reply.withUnsafeBytes { hasBundleBit($0.baseAddress! + MemoryLayout<UInt32>.size) }
    }

    private static let cache = Cache()

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var byExtension: [String: Bool] = [:]

        func isPackage(_ pathExtension: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if let known = byExtension[pathExtension] { return known }
            let isPackage =
                UTType(filenameExtension: pathExtension, conformingTo: .directory)?
                .conforms(to: .package) ?? false
            byExtension[pathExtension] = isPackage
            return isPackage
        }
    }
}
