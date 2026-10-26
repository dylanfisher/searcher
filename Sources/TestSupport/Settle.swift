import Foundation
import Testing

/// How long a test waits for something that must happen. Tests run in parallel on one main actor,
/// and a loaded machine can leave a test unscheduled for many seconds, so a short bound fails
/// tests that are correct. The bound only costs time when the thing never happens.
public let patience: TimeInterval = 60

/// Services the main queue until `condition` holds; fails the test after `patience`.
///
/// The location parameters are literals rather than `#_sourceLocation`, a Testing macro that a
/// non-test target can't reliably load.
@MainActor
public func settle(
    fileID: String = #fileID, filePath: String = #filePath, line: Int = #line,
    column: Int = #column, until condition: @MainActor () -> Bool
) async {
    let deadline = Date(timeIntervalSinceNow: patience)
    while !condition() {
        if Date() > deadline {
            Issue.record(
                "timed out waiting",
                sourceLocation: SourceLocation(
                    fileID: fileID, filePath: filePath, line: line, column: column))
            return
        }
        try? await Task.sleep(for: .milliseconds(2))
    }
}
