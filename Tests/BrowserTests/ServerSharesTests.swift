import BrowserTestSupport
import TestSupport
import Testing

@testable import Browser

private let dylans = ShareRequest(server: testServer, user: "dylan")
private let guests = ShareRequest(server: testServer, user: "guest")
private let names = ["docker", "main", "music"]

/// An ask of `shares` for `request`, running until the test reads its value.
@MainActor
private func ask(_ shares: ServerShares, _ request: ShareRequest = dylans)
    -> Task<Result<[String], ShareListError>?, Never>
{
    Task { await shares.names(for: request) }
}

/// A share list run that `enumerator` has started and answered with `result`, so `shares` holds
/// it from the clock's present.
@MainActor
private func answered(
    _ shares: ServerShares, _ enumerator: GatedShareEnumerator,
    _ result: Result<[String], ShareListError>, request: ShareRequest = dylans
) async {
    let starts = enumerator.starts.count
    let asking = ask(shares, request)
    #expect(await enumerator.waitForStarts(starts + 1))
    enumerator.answer(request, with: result)
    #expect(await asking.value == result)
}

@MainActor @Test func anAskStartsOneRunOnABlockingCallThreadAndASecondAskJoinsIt() async {
    let enumerator = GatedShareEnumerator()
    let shares = ServerShares(enumerator: enumerator, clock: ManualClock())
    let first = ask(shares)
    #expect(await enumerator.waitForStarts(1))
    let second = ask(shares)
    await settle { shares.askers(of: dylans) == 2 }

    enumerator.answer(dylans, with: .success(names))
    #expect(await first.value == .success(names))
    #expect(await second.value == .success(names))
    #expect(enumerator.starts.map(\.request) == [dylans])
    #expect(enumerator.starts.allSatisfy { $0.onBlockingCallThread && !$0.onMainThread })
}

@MainActor @Test func twoUsersOnOneHostRunTwoLists() async {
    let enumerator = GatedShareEnumerator()
    let shares = ServerShares(enumerator: enumerator, clock: ManualClock())
    let dylan = ask(shares, dylans)
    let guest = ask(shares, guests)
    #expect(await enumerator.waitForStarts(2))
    enumerator.answer(dylans, with: .success(names))
    enumerator.answer(guests, with: .success(["main"]))
    #expect(await dylan.value == .success(names))
    #expect(await guest.value == .success(["main"]))
    #expect(Set(enumerator.starts.map(\.request)) == [dylans, guests])
}

@MainActor @Test func theRunEndsOnlyWhenItsLastAskerIsCancelled() async {
    let enumerator = GatedShareEnumerator()
    let shares = ServerShares(enumerator: enumerator, clock: ManualClock())
    let first = ask(shares)
    let second = ask(shares)
    #expect(await enumerator.waitForStarts(1))
    await settle { shares.askers(of: dylans) == 2 }

    first.cancel()
    #expect(await first.value == nil)
    #expect(enumerator.terminations == 0)
    second.cancel()
    #expect(await second.value == nil)
    await settle { enumerator.terminations == 1 }

    // A cancelled run leaves nothing cached, so the next ask runs again.
    #expect(shares.cachedNames(for: dylans) == nil)
    await answered(shares, enumerator, .success(names))
    #expect(enumerator.starts.count == 2)
}

@MainActor @Test func namesAreKeptFor30Seconds() async {
    let clock = ManualClock()
    let enumerator = GatedShareEnumerator()
    let shares = ServerShares(enumerator: enumerator, clock: clock)
    await answered(shares, enumerator, .success(names))

    clock.advance(by: ServerShares.namesLifetime - .milliseconds(1))
    #expect(await shares.names(for: dylans) == .success(names))
    #expect(enumerator.starts.count == 1)

    clock.advance(by: .milliseconds(1))
    await answered(shares, enumerator, .success(["main"]))
    #expect(enumerator.starts.count == 2)
    #expect(shares.cachedNames(for: dylans) == ["main"])
}

@MainActor @Test func aFailureIsKeptFor10Seconds() async {
    let clock = ManualClock()
    let enumerator = GatedShareEnumerator()
    let shares = ServerShares(enumerator: enumerator, clock: clock)
    await answered(shares, enumerator, .failure(.rejected))

    clock.advance(by: ServerShares.failureBackoff - .milliseconds(1))
    #expect(await shares.names(for: dylans) == .failure(.rejected))
    #expect(enumerator.starts.count == 1)

    clock.advance(by: .milliseconds(1))
    await answered(shares, enumerator, .success(names))
    #expect(enumerator.starts.count == 2)
}

@MainActor @Test func aRunThatOutlastsTheGiveUpTimeIsUnreachableAndEnded() async {
    let clock = ManualClock()
    let enumerator = GatedShareEnumerator()
    let shares = ServerShares(enumerator: enumerator, clock: clock)
    let asking = ask(shares)
    #expect(await enumerator.waitForStarts(1))
    await settle { clock.waitingSleeps == 1 }

    clock.advance(by: LoadTimeouts.giveUp - .milliseconds(1))
    #expect(enumerator.terminations == 0)
    clock.advance(by: .milliseconds(1))
    #expect(await asking.value == .failure(.unreachable))
    await settle { enumerator.terminations == 1 }
    // Kept as a failure, so the next ask within the backoff starts nothing.
    #expect(await shares.names(for: dylans) == .failure(.unreachable))
    #expect(enumerator.starts.count == 1)
}

@MainActor @Test func aMissingToolIsTheAnswer() async {
    let enumerator = GatedShareEnumerator(startError: .toolMissing)
    let shares = ServerShares(enumerator: enumerator, clock: ManualClock())
    #expect(await shares.names(for: dylans) == .failure(.toolMissing))
}

@MainActor @Test func theLastNamesStayCachedPastTheirLifetime() async {
    let clock = ManualClock()
    let enumerator = GatedShareEnumerator()
    let shares = ServerShares(enumerator: enumerator, clock: clock)
    await answered(shares, enumerator, .success(names))
    clock.advance(by: .seconds(3600))
    #expect(shares.cachedNames(for: dylans) == names)
    #expect(shares.cachedNames(for: guests) == nil)
}

@MainActor @Test func forgettingAServerDropsTheEntriesOfEveryUser() async {
    let enumerator = GatedShareEnumerator()
    let shares = ServerShares(enumerator: enumerator, clock: ManualClock())
    let other = ShareRequest(server: Server(host: "nas.local")!, user: "dylan")
    await answered(shares, enumerator, .success(names), request: dylans)
    await answered(shares, enumerator, .success(["main"]), request: guests)
    await answered(shares, enumerator, .success(["photos"]), request: other)

    shares.forget(Server(host: testServerHost.uppercased())!)
    #expect(shares.cachedNames(for: dylans) == nil)
    #expect(shares.cachedNames(for: guests) == nil)
    #expect(shares.cachedNames(for: other) == ["photos"])
    await answered(shares, enumerator, .success(names), request: dylans)
    #expect(enumerator.starts.count == 4)
}

@MainActor @Test func stopEndsEveryRunAndAnswersItsAskersAsCancelled() async {
    let enumerator = GatedShareEnumerator()
    let shares = ServerShares(enumerator: enumerator, clock: ManualClock())
    let dylan = ask(shares, dylans)
    let guest = ask(shares, guests)
    #expect(await enumerator.waitForStarts(2))

    shares.stop()
    #expect(await dylan.value == nil)
    #expect(await guest.value == nil)
    await settle { enumerator.terminations == 2 }
}
