import Foundation
import TestSupport
import Testing

@testable import Bench

@Test func copyCaseIsJudgedAgainstS7() {
    let benchCase = BenchCase.copy(to: "/image")
    #expect(benchCase.budget == nil)
    #expect(benchCase.floor == .s7)
    #expect(benchCase.unit == .milliseconds)
}

@Test func copyRunCopiesThroughFileCopierAndRemovesTheCopy() async throws {
    let folder = try TemporaryFolder("CopyBenchTests")
    let source = folder.url.appending(path: "source")
    try Data(count: 100_000).write(to: source)
    let image = folder.url.appending(path: "image")
    try FileManager.default.createDirectory(at: image, withIntermediateDirectories: false)
    let milliseconds = try await BenchCase.timeCopy(source.path, into: image.path)
    #expect(milliseconds > 0)
    #expect(try FileManager.default.contentsOfDirectory(atPath: image.path) == [])
}
