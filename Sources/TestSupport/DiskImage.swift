import Foundation
import Testing

/// A disk image, 1 MB of HFS+ unless the test asks for another size or file system, attached with
/// `-nobrowse` at a folder inside its own temporary folder, so it shows nowhere under /Volumes or
/// in Finder. It is detached by its own device. If a test leaves it attached, releasing it forces a
/// detach, so no image outlives its test unless the test process dies. Creating one takes about a
/// second, so suites that use it are `.serialized` and keep to a few images.
///
/// `hdiutil` runs in its own process and the calls wait for it without blocking a thread, so a
/// test on the main actor doesn't hold up the other tests' main-queue work while it runs.
public final class DiskImage {
    /// Where the image is mounted, resolved, as the mount table and FSEvents report it.
    public let mountPoint: String
    /// The attached image's device, such as `/dev/disk4`; nil while it is detached.
    public private(set) var device: String?

    private let folder: TemporaryFolder
    private let image: String

    /// Creates an empty image of `megabytes` formatted as `fileSystem`, an `hdiutil create -fs`
    /// name such as "APFS", and attaches it, after detaching any that a test process which died
    /// left attached. A 1 MB APFS image has no room for a file; 2 MB has.
    public init(_ name: String = "DiskImage", megabytes: Int = 1, fileSystem: String = "HFS+")
        async throws
    {
        try await Self.staleImagesDetached.value
        // The process ID in the folder's name tells a later process whose image it is.
        folder = try TemporaryFolder("\(Self.folderPrefix)\(getpid())-\(name)")
        image = folder.url.appending(path: "image.dmg").path
        mountPoint = folder.url.appending(path: "mount").path
        try FileManager.default.createDirectory(
            atPath: mountPoint, withIntermediateDirectories: false)
        // exFAT and FAT take volume names of at most 11 characters.
        try await Self.hdiutil([
            "create", "-quiet", "-size", "\(megabytes)m", "-fs", fileSystem, "-layout", "NONE",
            "-volname", "SearcherTst", image,
        ])
        try await attach()
    }

    /// Attaches the image at `mountPoint` again after `detach`.
    public func attach() async throws {
        precondition(device == nil, "\(image) is already attached as \(device ?? "")")
        let output = try await Self.hdiutil([
            "attach", "-nobrowse", "-noverify", "-noautoopen", "-mountpoint", mountPoint, image,
        ])
        // One line per device: "/dev/disk4<tab>...<tab><mount point>".
        guard
            let line = output.split(separator: "\n").first(where: { $0.hasSuffix(mountPoint) }),
            let field = line.split(whereSeparator: \.isWhitespace).first
        else {
            throw Failure(arguments: ["attach", image], output: output)
        }
        device = String(field)
    }

    /// Detaches the image. Without `force`, an open file on the volume makes it fail.
    public func detach(force: Bool = false) async throws {
        guard let device else { preconditionFailure("\(image) isn't attached") }
        try await Self.hdiutil(Self.detachArguments(device, force: force))
        self.device = nil
    }

    deinit {
        guard let device else { return }
        // A deinit can't wait for a task, so this one call blocks.
        let call = HdiutilCall(Self.detachArguments(device, force: true))
        do {
            try call.process.run()
            call.process.waitUntilExit()
            _ = try call.result()
        } catch {
            // An explicit location, as in `TemporaryFolder`.
            Issue.record(
                error, "detaching \(image)",
                sourceLocation: SourceLocation(
                    fileID: #fileID, filePath: #filePath, line: #line, column: #column))
        }
    }

    /// An `hdiutil` call that exited with an error, and what it printed.
    public struct Failure: Error, CustomStringConvertible {
        public let arguments: [String]
        public let output: String

        public var description: String {
            "hdiutil \(arguments.joined(separator: " ")) failed: \(output)"
        }
    }

    /// Starts every image folder's name, before the process ID.
    private static let folderPrefix = "DiskImage-"

    /// Detaches, once per process, the images of test processes that died with them attached.
    /// It reads only images in this temporary folder whose folder names a process that is gone,
    /// so another test process's images are never touched.
    private static let staleImagesDetached = Task {
        let listing = try await hdiutil(["info", "-plist"])
        guard
            let info = try PropertyListSerialization.propertyList(
                from: Data(listing.utf8), format: nil) as? [String: Any],
            let images = info["images"] as? [[String: Any]]
        else {
            throw Failure(arguments: ["info", "-plist"], output: listing)
        }
        guard let temporary = realpath(FileManager.default.temporaryDirectory.path, nil) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let root = String(cString: temporary) + "/" + folderPrefix
        free(temporary)
        for image in images {
            guard let path = image["image-path"] as? String, path.hasPrefix(root),
                path.hasSuffix("/image.dmg"),
                let pid = path.dropFirst(root.count).split(separator: "-").first.flatMap({
                    pid_t($0)
                }),
                kill(pid, 0) == -1, errno == ESRCH,
                let device = (image["system-entities"] as? [[String: Any]])?
                    .compactMap({ $0["dev-entry"] as? String })
                    .min(by: { $0.count < $1.count })
            else { continue }
            try await hdiutil(detachArguments(device, force: true))
        }
    }

    private static func detachArguments(_ device: String, force: Bool) -> [String] {
        ["detach", "-quiet"] + (force ? ["-force"] : []) + [device]
    }

    /// Runs `hdiutil` and returns what it printed to standard output.
    @discardableResult
    private static func hdiutil(_ arguments: [String]) async throws -> String {
        let call = HdiutilCall(arguments)
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            call.process.terminationHandler = { _ in continuation.resume() }
            do {
                try call.process.run()
            } catch {
                call.process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        return try call.result()
    }
}

/// One run of `hdiutil`, with its output captured.
private struct HdiutilCall {
    let arguments: [String]
    let process = Process()
    private let output = Pipe()
    private let errors = Pipe()

    init(_ arguments: [String]) {
        self.arguments = arguments
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
    }

    /// What the finished call printed to standard output. hdiutil prints a few lines, well
    /// under a pipe's buffer, so reading after it exits can't stall it.
    func result() throws -> String {
        let printed = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            let message = String(
                decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw DiskImage.Failure(
                arguments: arguments, output: "exit \(process.terminationStatus): \(message)")
        }
        return printed
    }
}
