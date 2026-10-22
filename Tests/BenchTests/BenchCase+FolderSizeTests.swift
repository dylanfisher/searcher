import Foundation
import TestSupport
import Testing

@testable import Bench

@Test func folderSizeCaseCoversB5W3() {
    #expect(BenchCase.folderSize.map(\.budget?.id) == ["B5.W3"])
    #expect(BenchCase.registered.contains { $0.name == "walk W3: folder size" })
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
