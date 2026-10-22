import Foundation
import Testing

/// Services the main queue until `condition` holds; fails the test after 5 seconds.
///
/// The location parameters are literals rather than `#_sourceLocation`, a Testing macro that a
/// non-test target can't reliably load.
@MainActor
public func settle(
    fileID: String = #fileID, filePath: String = #filePath, line: Int = #line,
    column: Int = #column, until condition: @MainActor () -> Bool
) async {
    let deadline = Date(timeIntervalSinceNow: 5)
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
