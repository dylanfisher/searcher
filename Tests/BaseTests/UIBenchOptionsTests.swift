import Base
import Testing

@Test func optionsSurviveTheCommandLine() {
    let options = UIBenchOptions(
        output: "/o.json", w1: "/w1", w2: "/w2", keyPresses: 500, tempPrefix: "bench-7")
    #expect(UIBenchOptions(arguments: ["Searcher"] + options.arguments) == options)
}

@Test func launchWithoutTheFlagIsNotABench() {
    #expect(UIBenchOptions(arguments: ["Searcher", "--stall-threshold-ms", "50"]) == nil)
}
