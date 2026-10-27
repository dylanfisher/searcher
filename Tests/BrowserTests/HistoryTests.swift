import Testing

@testable import Browser

private func entry(_ path: String, _ selected: String? = nil) -> History.Entry {
    History.Entry(location: Location(path: path), selected: selected.map(ExactName.init))
}

@Test func backStepsThroughTheFoldersLeftInTurn() {
    var history = History()
    history.leave(entry("/a", "x"))
    history.leave(entry("/b", "y"))

    #expect(history.back(from: entry("/c")) == entry("/b", "y"))
    #expect(history.back(from: entry("/b", "y")) == entry("/a", "x"))
    #expect(!history.canGoBack)
}

@Test func forwardRetracesWhatBackStepped() {
    var history = History()
    history.leave(entry("/a"))
    history.leave(entry("/b"))
    _ = history.back(from: entry("/c", "z"))
    _ = history.back(from: entry("/b"))

    #expect(history.forward(from: entry("/a", "x")) == entry("/b"))
    #expect(history.forward(from: entry("/b")) == entry("/c", "z"))
    #expect(!history.canGoForward)
    #expect(history.back(from: entry("/c")) == entry("/b"))
}

@Test func leavingAfterBackClearsForward() {
    var history = History()
    history.leave(entry("/a"))
    _ = history.back(from: entry("/b"))
    #expect(history.canGoForward)

    history.leave(entry("/a"))

    #expect(!history.canGoForward)
    #expect(history.forward(from: entry("/d")) == nil)
}

@Test func emptyHistoryHasNothingEitherWay() {
    var history = History()

    #expect(!history.canGoBack)
    #expect(!history.canGoForward)
    #expect(history.back(from: entry("/a")) == nil)
    #expect(history.forward(from: entry("/a")) == nil)
    #expect(!history.canGoForward)
}

@Test func backAndForwardKeepAServer() {
    let server = Location.server(Server(mountSource: "//HAL9000._smb._tcp.local/music")!)
    let atServer = History.Entry(location: server, selected: ExactName("music"))
    var history = History()
    history.leave(atServer)

    #expect(history.back(from: entry("/Volumes/music")) == atServer)
    #expect(history.forward(from: atServer) == entry("/Volumes/music"))
}

/// `count` entries, oldest first, at /0, /1 and on.
private func entries(_ count: Int) -> [History.Entry] {
    (0..<count).map { entry("/\($0)") }
}

@Test func leavingPastTheLimitDropsTheOldestFolder() {
    var history = History()
    for left in entries(History.limit + 1) { history.leave(left) }

    #expect(history.backEntries == Array(entries(History.limit + 1).dropFirst()))
}

@Test func steppingKeepsEachWayWithinTheLimit() {
    // Full both ways, as a restored history can be.
    var history = History(back: entries(History.limit), forward: entries(History.limit))

    _ = history.back(from: entry("/back"))
    #expect(history.forwardEntries.count == History.limit)
    #expect(history.forwardEntries.first == entry("/1"))
    #expect(history.forwardEntries.last == entry("/back"))

    _ = history.forward(from: entry("/a"))
    _ = history.forward(from: entry("/b"))
    #expect(history.backEntries.count == History.limit)
    #expect(history.backEntries.last == entry("/b"))
}

/// A saved history longer than the limit keeps the entries nearest the folder each way.
@Test func aHistoryLongerThanTheLimitKeepsItsNearestEntries() {
    let long = entries(History.limit + 3)

    let history = History(back: long, forward: long)

    #expect(history.backEntries == Array(long.suffix(History.limit)))
    #expect(history.forwardEntries == Array(long.suffix(History.limit)))
}
