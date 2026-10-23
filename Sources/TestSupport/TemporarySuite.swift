import Foundation

/// A `UserDefaults` suite of its own, named by a path in `directory`, so a test never reads or
/// writes the user's preferences. cfprefsd stores it at that path plus `.plist`, and only once
/// something is written: a suite in a `TemporaryFolder` goes with the folder.
public func temporarySuite(in directory: String) -> UserDefaults {
    let name = (directory as NSString).appendingPathComponent("preferences-\(UUID().uuidString)")
    guard let defaults = UserDefaults(suiteName: name) else {
        preconditionFailure("UserDefaults refused the suite \(name)")
    }
    return defaults
}
