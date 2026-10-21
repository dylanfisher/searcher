import Foundation

/// A generated workload folder from the W1–W3 rows of docs/performance.md, built once from a seed
/// and reused by later runs. Files are sparse: they report their size but take almost no disk.
struct Fixture: Sendable {
    enum Workload: String, CaseIterable, Sendable {
        /// ~300 entries, Desktop/Downloads shape.
        case w1 = "W1"
        /// 100,000 entries in one folder: files plus 1% dot files and 1% empty folders.
        case w2 = "W2"
        /// node_modules shape, ~60k files in ~8k folders.
        case w3 = "W3"
    }

    /// One item to create, relative to the fixture folder; parents come before their children.
    struct Entry: Sendable, Equatable {
        let path: String
        /// Nil for a folder.
        let size: Int64?
        /// Seconds since 1970. Seeded, so sorting by date doesn't fall through to the name.
        let modified: Int64
    }

    /// The seed the runner builds with. Changing it builds a new set of fixtures beside the old.
    static let seed: UInt64 = 42
    /// Keeps Spotlight from indexing a fixture while it's built and timed.
    static let neverIndexMarker = ".metadata_never_index"
    /// `$TMPDIR/searcher-bench`, the only place the runner writes fixtures.
    static let root = FileManager.default.temporaryDirectory.appending(path: "searcher-bench")
    /// Modification dates fall in 2022 through 2025.
    static let modifiedRange: ClosedRange<Int64> = 1_640_995_200...1_767_225_599

    let workload: Workload
    let seed: UInt64
    let root: URL
    /// Everything the fixture holds, the marker first, in creation order.
    let entries: [Entry]

    init(_ workload: Workload, seed: UInt64 = Fixture.seed, root: URL = Fixture.root) {
        self.init(workload, seed: seed, root: root, entries: Self.generate(workload, seed: seed))
    }

    /// For tests that need an entry list the generator doesn't make.
    init(_ workload: Workload, seed: UInt64, root: URL, entries: [Entry]) {
        self.workload = workload
        self.seed = seed
        self.root = root
        self.entries = entries
    }

    /// `W2-42-`: what every build of this workload and seed is named with, whatever its entries.
    private var prefix: String { "\(workload.rawValue)-\(seed)-" }

    /// `W2-42-<digest>`. The digest covers the entry list, so a change to the generator builds a
    /// new fixture instead of reusing one with the old shape.
    private var name: String { prefix + Self.digest(of: entries) }

    /// The finished fixture. Only a complete build is ever at this path.
    var path: URL { root.appending(path: name) }

    /// Builds the fixture unless a finished one is already at `path`, and returns whether it
    /// built. Any other build of this workload and seed (one with an older entry list, or a
    /// partial folder a crash left) is removed first. The build goes into a partial folder beside
    /// `path` and is renamed into place when complete, so an interrupted build is never mistaken
    /// for a fixture. `beforeRename` runs just before the rename; tests use it to look at the
    /// partial folder and to interrupt a build. Call it off the main thread.
    @discardableResult
    func prepare(beforeRename: () throws -> Void = {}) throws -> Bool {
        let files = FileManager.default
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        for other in try files.contentsOfDirectory(atPath: root.path)
        where other != name && (other.hasPrefix(prefix) || other.hasPrefix("." + prefix)) {
            try files.removeItem(at: root.appending(path: other))
        }
        if files.fileExists(atPath: path.path) { return false }
        let partial = root.appending(path: ".\(name).partial-\(UUID().uuidString)")
        try files.createDirectory(at: partial, withIntermediateDirectories: false)
        do {
            for entry in entries {
                try Self.create(entry, in: partial.path)
            }
            // A separate pass after everything exists: creating an entry moves its folder's date,
            // but setting an entry's date doesn't.
            for entry in entries {
                try Self.setModified(entry, in: partial.path)
            }
            try beforeRename()
            try files.moveItem(at: partial, to: path)
        } catch {
            do {
                try files.removeItem(at: partial)
            } catch let cleanup {
                throw BuildFailed(
                    description: "\(error); removing \(partial.path) then failed: \(cleanup)")
            }
            throw error
        }
        return true
    }

    struct BuildFailed: Error, CustomStringConvertible {
        let description: String
    }

    private static func generate(_ workload: Workload, seed: UInt64) -> [Entry] {
        var generator = SeededGenerator(seed: seed)
        var entries: [Entry] = []
        let span = Int(modifiedRange.upperBound - modifiedRange.lowerBound)
        func add(_ path: String, size: Int64?) {
            let offset = Int64(generator.int(in: 0...span))
            entries.append(
                Entry(path: path, size: size, modified: modifiedRange.lowerBound + offset))
        }
        add(neverIndexMarker, size: 0)
        switch workload {
        case .w1:
            for index in 0..<40 {
                add(uniqueName(index, &generator), size: nil)
            }
            for index in 40..<300 {
                add(
                    uniqueName(index, &generator) + "." + generator.element(of: extensions),
                    size: Int64(generator.int(in: 0...50_000_000)))
            }
        case .w2:
            // Every hundredth index is a dot file and the one after it an empty folder, so the
            // shares are exactly 1% each.
            for index in 0..<100_000 {
                let name = uniqueName(index, &generator)
                switch index % 100 {
                case 0:
                    add(
                        "." + name + "." + generator.element(of: extensions),
                        size: Int64(generator.int(in: 0...5_000_000)))
                case 1:
                    add(name, size: nil)
                default:
                    add(
                        name + "." + generator.element(of: extensions),
                        size: Int64(generator.int(in: 0...5_000_000)))
                }
            }
        case .w3:
            add("node_modules", size: nil)
            for package in 0..<800 {
                var folders = ["node_modules/pkg-\(package)"]
                add(folders[0], size: nil)
                for index in 0..<generator.int(in: 6...14) {
                    let folder =
                        generator.element(of: folders) + "/"
                        + generator.element(of: packageFolders) + "-\(index)"
                    folders.append(folder)
                    add(folder, size: nil)
                }
                for index in 0..<generator.int(in: 40...110) {
                    add(
                        generator.element(of: folders) + "/f\(index)."
                            + generator.element(of: packageExtensions),
                        size: Int64(generator.int(in: 0...40_000)))
                }
            }
        }
        return entries
    }

    private static func create(_ entry: Entry, in folder: String) throws {
        let path = folder + "/" + entry.path
        guard let size = entry.size else {
            guard mkdir(path, 0o755) == 0 else { throw failure("mkdir", path) }
            return
        }
        let descriptor = open(path, O_CREAT | O_WRONLY | O_EXCL, 0o644)
        guard descriptor >= 0 else { throw failure("create", path) }
        defer { close(descriptor) }
        guard ftruncate(descriptor, size) == 0 else { throw failure("ftruncate", path) }
    }

    private static func setModified(_ entry: Entry, in folder: String) throws {
        let path = folder + "/" + entry.path
        let time = timespec(tv_sec: Int(entry.modified), tv_nsec: 0)
        guard utimensat(AT_FDCWD, path, [time, time], 0) == 0 else {
            throw failure("utimensat", path)
        }
    }

    private static func failure(_ call: String, _ path: String) -> BuildFailed {
        BuildFailed(description: "\(call) \(path): \(String(cString: strerror(errno)))")
    }

    /// FNV-1a over every field of every entry, as 8 hex digits. Two entry lists with the same
    /// digest would reuse each other's fixture; at 32 bits that's a one in four billion chance
    /// per generator change.
    private static func digest(of entries: [Entry]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for entry in entries {
            for byte in "\(entry.path)\0\(entry.size ?? -1)\0\(entry.modified)\n".utf8 {
                hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
            }
        }
        let short = String(hash >> 32, radix: 16)
        return String(repeating: "0", count: 8 - short.count) + short
    }

    /// A unique name: a word, the index, and a random number, so sorting by name shuffles the
    /// creation order.
    private static func uniqueName(_ index: Int, _ generator: inout SeededGenerator) -> String {
        "\(generator.element(of: words))-\(index)-\(UInt32(truncatingIfNeeded: generator.next()))"
    }

    private static let words = [
        "report", "photo", "invoice", "notes", "draft", "final", "scan", "mix", "track", "index",
        "Ünïcødé", "日本語",
    ]
    private static let extensions = [
        "txt", "png", "jpg", "pdf", "swift", "md", "json", "zip", "mov", "flac",
    ]
    private static let packageFolders = [
        "lib", "dist", "src", "test", "esm", "cjs", "types", "node_modules",
    ]
    private static let packageExtensions = ["js", "ts", "json", "map", "md"]
}
