import Foundation
import Testing

@testable import Interface

/// Finder's words: "N items", "1 item", "0 items", and the space after a comma once known.
@Test func theTextCountsItemsAsFinderDoes() {
    #expect(StatusBarText.text(items: 0, selected: 0, available: nil) == "0 items")
    #expect(StatusBarText.text(items: 1, selected: 0, available: nil) == "1 item")
    #expect(StatusBarText.text(items: 6, selected: 0, available: nil) == "6 items")
    #expect(
        StatusBarText.text(items: 6, selected: 0, available: 789_740_000_000)
            == "6 items, 789.74 GB available")
    #expect(
        StatusBarText.text(items: 1, selected: 0, available: 2_000_000_000_000)
            == "1 item, 2 TB available")
    #expect(
        StatusBarText.text(items: 0, selected: 0, available: 512_000_000)
            == "0 items, 512 MB available")
}

/// With a selection it says how many of how many, as Finder does.
@Test func aSelectionSaysHowManyOfHowMany() {
    #expect(StatusBarText.text(items: 6, selected: 1, available: nil) == "1 of 6 selected")
    #expect(
        StatusBarText.text(items: 6, selected: 2, available: 789_740_000_000)
            == "2 of 6 selected, 789.74 GB available")
    #expect(
        StatusBarText.text(items: 1, selected: 1, available: nil) == "1 of 1 selected")
}
