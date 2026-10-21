import Darwin
import Foundation
import Testing

/// A folder under the temporary directory, removed when the test releases it. `url` is the
/// resolved path, since FSEvents reports resolved paths (`/private/var`, not `/var`).
public final class TemporaryFolder {
    public let url: URL

    public init(_ name: String = "TemporaryFolder") throws {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "\(name)-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(
            atPath: path, withIntermediateDirectories: false)
        guard let resolved = realpath(path, nil) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { free(resolved) }
        url = URL(fileURLWithPath: String(cString: resolved))
    }

    deinit {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            // An explicit location: the default argument is a macro, and a non-test target can't
            // reliably load the Testing macro plugin.
            Issue.record(
                error, "removing \(url.path)",
                sourceLocation: SourceLocation(
                    fileID: #fileID, filePath: #filePath, line: #line, column: #column))
        }
    }
}
