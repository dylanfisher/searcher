import Foundation

/// The disk image a run copies to, and the free space it and the fixture it copies from need.
/// scripts/bench asks for it (`--disk-image-size`) before it creates the image or the runner
/// writes a fixture, and stops when the space is short. The image is sparse and sits in the same
/// temporary folder as the fixtures, so both come out of one volume's free space.
struct DiskImagePlan: Equatable {
    /// The fixture the run copies to the image.
    let source: Fixture
    /// What `source` still needs written: its size, or 0 when it is built.
    let sourceBytes: Int64
    /// The most the image grows to: the bytes copied to it, plus room for the file system.
    let imageBytes: Int64

    /// Room in the image beyond the bytes copied: APFS's own metadata and the block rounding of
    /// W8's 20,000 small files, about 40 MB at 4 KiB blocks, with margin.
    static let imageHeadroom: Int64 = 512_000_000

    init(source: Fixture) {
        self.source = source
        sourceBytes = source.isBuilt ? 0 : source.bytes
        imageBytes = source.bytes + Self.imageHeadroom
    }

    /// The plan of a run that copies to a disk image, or nil for one that doesn't: the harness
    /// run copies the 1 GB source, and the UI bench's CI run copies W8 or its CI variant. Reads
    /// whether the fixture is built and writes nothing.
    init?(for arguments: BenchArguments, root: URL = Fixture.root) {
        switch arguments {
        case .run:
            self.init(source: Fixture(.copySource, root: root))
        case .ui(_, _, nil, _, let w8):
            self.init(source: Fixture(w8, root: root))
        case .ui, .printBudget, .checkIdle, .footprintOfOpening, .coldChildren, .compare,
            .compareUI, .help, .printStallArguments, .diskImageSize:
            return nil
        }
    }

    /// The image's size as `hdiutil create -size <n>m` takes it, rounded up.
    var imageMegabytes: Int64 { (imageBytes + 999_999) / 1_000_000 }

    /// Throws unless `free` bytes cover the source and the image, naming each.
    func check(free: Int64, in folder: String) throws(Shortfall) {
        guard sourceBytes + imageBytes > free else { return }
        throw Shortfall(
            folder: folder, fixture: source.workload.rawValue, sourceBytes: sourceBytes,
            imageBytes: imageBytes, free: free)
    }

    struct Shortfall: Error, CustomStringConvertible {
        let folder: String
        let fixture: String
        let sourceBytes: Int64
        let imageBytes: Int64
        let free: Int64

        var description: String {
            "not enough free space in \(folder): the \(fixture) fixture needs \(sourceBytes) "
                + "bytes and the disk image \(imageBytes) bytes, \(sourceBytes + imageBytes) "
                + "bytes in all, and \(free) bytes are free"
        }
    }

    /// The bytes free to an unprivileged process on the volume holding `folder`.
    static func freeBytes(in folder: String) throws -> Int64 {
        var info = statfs()
        guard statfs(folder, &info) == 0 else {
            throw FreeSpaceUnreadable(
                description: "statfs \(folder): \(String(cString: strerror(errno)))")
        }
        return Int64(info.f_bavail) * Int64(info.f_bsize)
    }

    struct FreeSpaceUnreadable: Error, CustomStringConvertible {
        let description: String
    }
}
