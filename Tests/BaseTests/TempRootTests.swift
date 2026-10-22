import Base
import Foundation
import Testing

/// Every plist in ~/Library/Preferences whose name starts with `prefix`, where cfprefsd keeps a
/// suite named by a plain name.
private func userPreferences(startingWith prefix: String) throws -> [String] {
    let folder = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Preferences")
    return try FileManager.default.contentsOfDirectory(atPath: folder.path)
        .filter { $0.hasPrefix(prefix) }
}

/// Writes a key and waits for cfprefsd to put the suite's file on disk.
private func write(_ root: TempRoot) throws {
    try #require(UserDefaults(suiteName: root.suiteName)).set(true, forKey: "written")
    #expect(CFPreferencesAppSynchronize(root.suiteName as CFString))
}

@Test func twoRootsGetDifferentFoldersAndSuitesAndRemoveBoth() throws {
    let first = try TempRoot(prefix: "TempRootTests")
    let second = try TempRoot(prefix: "TempRootTests")
    #expect(first.folder != second.folder)
    #expect(first.suiteName != second.suiteName)

    for root in [first, second] {
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: root.folder.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        try write(root)
        // The suite's file is in the folder, so removing the folder removes it.
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: root.folder.path)
                == ["preferences.plist"])
        #expect(UserDefaults(suiteName: root.suiteName)?.bool(forKey: "written") == true)
    }
    #expect(try userPreferences(startingWith: "TempRootTests").isEmpty)

    try first.remove()
    try second.remove()

    for root in [first, second] {
        #expect(!FileManager.default.fileExists(atPath: root.folder.path))
    }
}

/// A prefix only the exit test below uses, so a plist left by it can be told from others.
private let exitTestPrefix = "TempRootTestsExit"

@Test func aProcessThatWroteAndRemovedItsRootLeavesNoPreferencesBehind() async throws {
    // In a child process, so the check runs after the process that used the suite has exited,
    // which is when cfprefsd writes a plain-named suite's plist back. The closure can't capture
    // `exitTestPrefix`, so it spells the prefix out.
    await #expect(processExitsWith: .success) {
        let root = try TempRoot(prefix: "TempRootTestsExit")
        try #require(UserDefaults(suiteName: root.suiteName)).set(true, forKey: "written")
        #expect(CFPreferencesAppSynchronize(root.suiteName as CFString))
        try root.remove()
    }
    try await Task.sleep(for: .seconds(1))
    #expect(try userPreferences(startingWith: exitTestPrefix).isEmpty)
    #expect(
        try FileManager.default.contentsOfDirectory(
            atPath: FileManager.default.temporaryDirectory.path
        ).filter { $0.hasPrefix(exitTestPrefix + "-") }.isEmpty)
}

@Test func removeAllWithAPrefixRemovesWhatAKilledOwnerLeftAndNothingElse() throws {
    let prefix = "TempRootTests-\(UUID().uuidString)"
    let leftovers = [try TempRoot(prefix: prefix), try TempRoot(prefix: prefix)]
    let other = try TempRoot(prefix: "TempRootTests-other")
    for root in leftovers + [other] { try write(root) }

    try TempRoot.removeAll(prefix: prefix)

    for root in leftovers {
        #expect(!FileManager.default.fileExists(atPath: root.folder.path))
    }
    #expect(FileManager.default.fileExists(atPath: other.folder.path))
    try other.remove()
}

@Test func removeAllRejectsAPrefixWithASlash() async {
    await #expect(processExitsWith: .failure) { try TempRoot.removeAll(prefix: "a/b") }
}

// Without the check, this removes everything in the temporary directory named `-*`.
@Test func removeAllRejectsAnEmptyPrefix() async {
    await #expect(processExitsWith: .failure) { try TempRoot.removeAll(prefix: "") }
}
