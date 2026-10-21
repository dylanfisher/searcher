import Base
import Testing

private let zero = ContinuousClock.now

private func at(_ milliseconds: Int) -> ContinuousClock.Instant {
    zero + .milliseconds(milliseconds)
}

/// "open W2" from 100 to 160 ms, "key down" from 200 to 210 ms.
private let spans = [
    TimedSpan(name: "open W2", start: at(100), end: at(160)),
    TimedSpan(name: "key down", start: at(200), end: at(210)),
]

@Test func aStallInThePassThatEndsASpanIsFiledUnderThatSpan() {
    // The pass started inside the span and ended after its frame was timed, as the pass that
    // commits the span's frame does.
    #expect(TimedSpan.name(coveringPassFrom: at(150), to: at(220), in: spans) == "open W2")
}

@Test func aStallInsideASpanIsFiledUnderIt() {
    #expect(TimedSpan.name(coveringPassFrom: at(201), to: at(209), in: spans) == "key down")
}

@Test func aStallInAPassThatStartsBeforeASpanIsFiledUnderIt() {
    // `begin()` runs partway through a pass, so the pass that does a span's work starts before
    // the span does.
    #expect(TimedSpan.name(coveringPassFrom: at(195), to: at(205), in: spans) == "key down")
}

@Test func aStallOutsideEverySpanIsFiledUnderNone() {
    #expect(TimedSpan.name(coveringPassFrom: at(165), to: at(195), in: spans) == nil)
    #expect(TimedSpan.name(coveringPassFrom: at(300), to: at(400), in: spans) == nil)
}
