import Base
import TestSupport
import Testing

@Test func deadlineWaitCountsFromWhenItStarted() async {
    let clock = ManualClock()
    let wait = DeadlineWait.make(on: clock)(.seconds(2))
    clock.advance(by: .seconds(2))
    #expect(await DeadlineWait.reached(wait))
}

@MainActor
@Test func deadlineWaitEndsAtItsDeadline() async {
    let clock = ManualClock()
    let wait = DeadlineWait.make(on: clock)(.seconds(2))
    let task = Task { await DeadlineWait.reached(wait) }
    await settle { clock.waitingSleeps == 1 }
    clock.advance(by: .seconds(1))
    #expect(clock.waitingSleeps == 1)
    clock.advance(by: .seconds(1))
    #expect(await bounded(task) == true)
}

@MainActor
@Test func deadlineWaitCancelledReturnsFalse() async {
    let clock = ManualClock()
    let wait = DeadlineWait.make(on: clock)(.seconds(2))
    let task = Task { await DeadlineWait.reached(wait) }
    await settle { clock.waitingSleeps == 1 }
    task.cancel()
    #expect(await bounded(task) == false)
}

private struct ClockBroke: Error {}

@Test func deadlineWaitTrapsOnAnyOtherError() async {
    await #expect(processExitsWith: .failure) {
        _ = await DeadlineWait.reached { throw ClockBroke() }
    }
}
