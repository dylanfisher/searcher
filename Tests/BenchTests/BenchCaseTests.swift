import Testing

@testable import Bench

private actor Calls {
    private(set) var warmUps = 0
    private(set) var runs = 0
    func warmUp() { warmUps += 1 }
    func run() -> Double {
        runs += 1
        return Double(runs)
    }
}

@Test func measureWarmsUpOnceAndKeepsTheWarmUpOutOfTheSamples() async throws {
    let calls = Calls()
    let benchCase = BenchCase(
        name: "counted", budget: nil, unit: .milliseconds, runs: 4,
        warmUp: { _ in await calls.warmUp() },
        run: { _ in await calls.run() })
    let samples = try await benchCase.measure(folder: nil)
    #expect(samples.sorted == [1, 2, 3, 4])
    #expect(await calls.warmUps == 1)
    #expect(await calls.runs == 4)
}
