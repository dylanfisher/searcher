import Foundation
import Testing

@testable import Bench

@Test func openFolderCasesCoverTheirBudgets() {
    let ids = BenchCase.openFolder.compactMap(\.budget?.id)
    #expect(ids == ["B2.W1", "B2.W2", "B5.W2", "B9", "B2.W2"])
    #expect(BenchCase.openFolder.contains { $0.name.contains("×10") && $0.budget == nil })
    // The focused pane's first rows while nine other loads wait or run are held to B2.
    #expect(
        BenchCase.openFolder.contains {
            $0.name.contains("×10") && $0.name.contains("focused") && $0.budget?.id == "B2.W2"
        })
}

@Test func openFolderCasesRunOnAFolder() async throws {
    // More entries than one getattrlistbulk buffer holds, so loads send a first batch.
    let folder = FileManager.default.temporaryDirectory
        .appending(path: "OpenFolderTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    defer {
        do {
            try FileManager.default.removeItem(at: folder)
        } catch {
            Issue.record(error, "removing \(folder.path)")
        }
    }
    for index in 0..<2_500 {
        try Data().write(to: folder.appending(path: "file-\(index)"))
    }

    // The memory case runs the Bench executable, which a test run doesn't have; its body is
    // `footprintOfOpening`, run here in-process.
    for benchCase in BenchCase.openFolder where benchCase.unit == .milliseconds {
        #expect(try await benchCase.run(folder.path) > 0, "\(benchCase.name)")
    }
    #expect(try await BenchCase.footprintOfOpening(folder.path).isFinite)
}

@Test func openFolderFailsOnAMissingFolder() async {
    let missing = FileManager.default.temporaryDirectory
        .appending(path: "OpenFolderTests-missing-\(UUID().uuidString)").path
    await #expect(throws: (any Error).self) {
        try await BenchCase.openFolder[0].run(missing)
    }
}
