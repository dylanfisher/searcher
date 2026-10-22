import Base
import Testing

@Test func p95IsNearestRank() {
    // Nearest rank for p95 of 20 values is the 19th smallest.
    let samples = Samples([20, 3, 17, 1, 9, 14, 6, 19, 11, 2, 16, 8, 13, 5, 18, 10, 4, 15, 7, 12])
    #expect(samples.p95 == 19)
}

@Test func p95OfTenIsTheLargest() {
    #expect(Samples([5, 1, 4, 2, 3, 10, 9, 8, 7, 6]).p95 == 10)
}

@Test func medianIsNearestRank() {
    #expect(Samples([4, 1, 3, 2]).median == 2)
    #expect(Samples([5, 1, 3]).median == 3)
}
