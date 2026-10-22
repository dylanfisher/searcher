import Foundation
import TestSupport
import Testing

@testable import Bench

@Test func viewSettingsCasesCoverB8OnW2AndReportW5() {
    let cases = BenchCase.viewSettings
    #expect(cases.filter { $0.name.hasPrefix("W2") }.allSatisfy { $0.budget?.id == "B8" })
    #expect(cases.filter { $0.name.hasPrefix("W5") }.allSatisfy { $0.budget == nil })
    #expect(cases.count == 7)
    #expect(BenchCase.registered.contains { $0.name == "W5: show hidden files" })
}

@Test func viewSettingsCasesRunOnAFolder() async throws {
    let folder = try TemporaryFolder("ViewSettingsTests")
    try FileManager.default.createDirectory(
        at: folder.url.appending(path: "a folder"), withIntermediateDirectories: false)
    for name in [".hidden", "b", "c"] {
        try Data([1]).write(to: folder.url.appending(path: name))
    }

    for benchCase in BenchCase.viewSettings {
        #expect(try await benchCase.run(folder.url.path) > 0, "\(benchCase.name)")
    }
}
