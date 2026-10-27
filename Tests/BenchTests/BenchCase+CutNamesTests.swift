import Testing

@testable import Bench

@Test func cutNamesCasesAreRegisteredAndTheRepeatedReadIsUnderB6() {
    let cases = BenchCase.cutNames
    #expect(cases.map(\.budget?.id) == ["B6", nil])
    #expect(
        cases.allSatisfy { benchCase in BenchCase.registered.contains { $0.name == benchCase.name }
        })
}
