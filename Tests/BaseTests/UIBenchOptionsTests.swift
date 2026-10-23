import Base
import Testing

@Test func optionsSurviveTheCommandLine() {
    let options = UIBenchOptions(
        output: "/o.json", w1: "/w1", w2: "/w2", keyPresses: 500, tempPrefix: "bench-7",
        scenario: nil, folders: [])
    #expect(UIBenchOptions(arguments: ["Searcher"] + options.arguments) == options)
}

@Test func scenarioAndFoldersSurviveTheCommandLineBeforeOtherArguments() {
    let options = UIBenchOptions(
        output: "/o.json", w1: "/nas", w2: "/nas", keyPresses: 0, tempPrefix: "bench-7",
        scenario: .cold, folders: ["/nas/a", "/nas/b c"])
    #expect(
        UIBenchOptions(
            arguments: ["Searcher"] + options.arguments + ["--stall-threshold-ms", "50"])
            == options)
}

@Test func theW8CopySurvivesTheCommandLine() {
    let options = UIBenchOptions(
        output: "/o.json", w1: "/w1", w2: "/w2", keyPresses: 500, tempPrefix: "bench-7",
        scenario: nil, folders: [], w8: "/w8", image: "/image mount")
    #expect(UIBenchOptions(arguments: ["Searcher"] + options.arguments) == options)
}

@Test func launchWithoutTheFlagIsNotABench() {
    #expect(UIBenchOptions(arguments: ["Searcher", "--stall-threshold-ms", "50"]) == nil)
}
