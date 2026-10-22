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
