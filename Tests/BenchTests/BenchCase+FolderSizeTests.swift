import Foundation
import TestSupport
import Testing

@testable import Bench

@Test func folderSizeCasesCoverB5W3AndTheResortOfB8() {
    #expect(BenchCase.folderSize.map(\.budget?.id) == ["B5.W3", "B8"])
    #expect(BenchCase.registered.contains { $0.name == "walk W3: folder size" })
    #expect(BenchCase.registered.contains { $0.name == "W2: size updates re-sorted" })
}

@Test func folderSizeCaseRunsOnAFolder() async throws {
    let folder = try TemporaryFolder("FolderSizeBenchTests")
    try FileManager.default.createDirectory(
        at: folder.url.appending(path: "a/b"), withIntermediateDirectories: true)
    try Data(count: 10).write(to: folder.url.appending(path: "a/b/file"))
    for benchCase in BenchCase.folderSize {
        #expect(try await benchCase.run(folder.url.path) > 0)
    }
}
