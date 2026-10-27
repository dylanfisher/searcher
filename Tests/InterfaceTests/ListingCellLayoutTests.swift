import Testing

@testable import Interface

@MainActor
@Test func theBadgeSitsAtTheTrailingEdgeOrLeftOfTheChevron() {
    #expect(ListingCellLayout.badgeX(cellWidth: 200, chevronRoom: nil) == 182)
    #expect(ListingCellLayout.badgeX(cellWidth: 200, chevronRoom: 4) == 176)
}

@MainActor
@Test func theNameEndsBeforeTheBadgeElseTheChevronElseThePadding() {
    #expect(ListingCellLayout.nameEnd(cellWidth: 200, chevronRoom: 4, badge: true) == 172)
    #expect(ListingCellLayout.nameEnd(cellWidth: 200, chevronRoom: 4, badge: false) == 192)
    #expect(ListingCellLayout.nameEnd(cellWidth: 200, chevronRoom: nil, badge: false) == 198)
}

@MainActor
@Test func theChevronTakesLessRoomInTheRoundedBand() {
    #expect(ListingCellLayout.chevronRoom(for: .roundedBand) == 4)
    #expect(ListingCellLayout.chevronRoom(for: .fullWidth) == 6)
}
