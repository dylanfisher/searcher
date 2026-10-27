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

/// The eject button ends where the chevron starts, else at the cell's edge, and the name ends
/// where the button starts (docs/decisions/0118-row-eject-buttons.md).
@MainActor
@Test func theEjectButtonEndsAtTheChevronElseTheEdgeAndTheNameBeforeIt() {
    #expect(ListingCellLayout.ejectX(cellWidth: 200, chevronRoom: nil) == 178)
    #expect(ListingCellLayout.ejectX(cellWidth: 200, chevronRoom: 4) == 174)
    #expect(
        ListingCellLayout.nameEnd(cellWidth: 200, chevronRoom: 4, badge: false, eject: true)
            == 174)
    #expect(
        ListingCellLayout.nameEnd(cellWidth: 200, chevronRoom: nil, badge: false, eject: true)
            == 178)
}

@MainActor
@Test func theChevronTakesLessRoomInTheRoundedBand() {
    #expect(ListingCellLayout.chevronRoom(for: .roundedBand) == 4)
    #expect(ListingCellLayout.chevronRoom(for: .fullWidth) == 6)
}
