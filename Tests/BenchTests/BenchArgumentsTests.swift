import Foundation
import Testing

@testable import Bench

@Test func missingPathFailsNamingIt() {
    let missing = FileManager.default.temporaryDirectory
        .appending(path: "searcher-bench-missing-\(UUID().uuidString)").path
    #expect {
        try BenchArguments.parse(["--path", missing])
    } throws: { error in
        String(describing: error).contains(missing)
    }
}

@Test func existingPathIsPassedToCases() throws {
    let folder = FileManager.default.temporaryDirectory.path
    #expect(try BenchArguments.parse(["--path", folder]) == .run(folder: folder))
}

@Test func noArgumentsRunsWithoutFolder() throws {
    #expect(try BenchArguments.parse([]) == .run(folder: nil))
}

@Test func printBudgetNamesOneBudget() throws {
    #expect(
        try BenchArguments.parse(["--print-budget", "B10"]) == .printBudget(Budget.named("B10")))
}

@Test func stallArgumentsAreTheWatchdogFlagWithB10() throws {
    #expect(try BenchArguments.parse(["--print-stall-arguments"]) == .printStallArguments)
    #expect(try BenchArguments.stallArguments() == ["--stall-threshold-ms", "50"])
}

@Test func checkIdleSamplesTheMachine() throws {
    #expect(try BenchArguments.parse(["--check-idle"]) == .checkIdle)
}

@Test func unknownArgumentFailsNamingIt() {
    #expect {
        try BenchArguments.parse(["--frobnicate"])
    } throws: { error in
        String(describing: error).contains("--frobnicate")
    }
}

@Test func footprintOfOpeningNamesTheFolder() throws {
    #expect(
        try BenchArguments.parse([BenchCase.footprintArgument, "/w2"])
            == .footprintOfOpening(folder: "/w2"))
}

@Test func uiNamesTheAppAndKeepsThePath() throws {
    let folder = FileManager.default.temporaryDirectory.path
    #expect(
        try BenchArguments.parse(["--path", folder, "--ui", "/b/Searcher.app"])
            == .ui(app: "/b/Searcher.app", folder: folder, scenario: nil))
    #expect(
        try BenchArguments.parse(["--ui", "/b/Searcher.app"])
            == .ui(app: "/b/Searcher.app", folder: nil, scenario: nil))
}
