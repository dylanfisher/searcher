import Foundation
import ObjectiveC
import Testing

/// A `UserDefaults` suite of its own, named by a path in `directory`, so a test never reads or
/// writes the user's preferences. cfprefsd stores it at that path plus `.plist`. The suite's file
/// is removed when the returned object is released, so a suite in the shared temporary directory
/// leaves nothing behind; one in a `TemporaryFolder` goes with the folder either way.
public func temporarySuite(in directory: String) -> UserDefaults {
    let name = (directory as NSString).appendingPathComponent("preferences-\(UUID().uuidString)")
    guard let defaults = UserDefaults(suiteName: name) else {
        preconditionFailure("UserDefaults refused the suite \(name)")
    }
    objc_setAssociatedObject(
        defaults, &suiteRemoverKey, SuiteRemover(name: name), .OBJC_ASSOCIATION_RETAIN)
    return defaults
}

nonisolated(unsafe) private var suiteRemoverKey: UInt8 = 0

/// Removes the suite named `name` and its file when it is released.
private final class SuiteRemover {
    let name: String

    init(name: String) {
        self.name = name
    }

    deinit {
        // A suite in a `TemporaryFolder` that was released first has nothing left to remove, and
        // opening it would make cfprefsd create the folder again, empty.
        let parent = (name as NSString).deletingLastPathComponent
        guard FileManager.default.fileExists(atPath: parent) else { return }
        UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        let file = name + ".plist"
        guard FileManager.default.fileExists(atPath: file) else { return }
        do {
            try FileManager.default.removeItem(atPath: file)
        } catch {
            // An explicit location: see `TemporaryFolder`.
            Issue.record(
                error, "removing \(file)",
                sourceLocation: SourceLocation(
                    fileID: #fileID, filePath: #filePath, line: #line, column: #column))
        }
    }
}
