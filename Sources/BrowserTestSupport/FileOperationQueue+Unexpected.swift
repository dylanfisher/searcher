import Browser
import Testing

extension FileOperationQueue.Prompts {
    /// For operations that ask nothing: a question fails the test. The issue is recorded here
    /// rather than where the queue asked, because the location is a literal: `#_sourceLocation`
    /// is a Testing macro that a non-test target can't reliably load.
    public static let unexpected = FileOperationQueue.Prompts(
        resolve: { request in
            Issue.record("unexpected conflict \(request)", sourceLocation: here)
            return ConflictResolution(choice: .skip, appliesToAll: true)
        },
        confirm: { request in
            Issue.record("unexpected confirm \(request)", sourceLocation: here)
            return false
        })
}

private let here = SourceLocation(
    fileID: #fileID, filePath: #filePath, line: #line, column: #column)
