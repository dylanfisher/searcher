import Base
import Foundation
import TestSupport
import Testing

@testable import Browser

/// A loaded pane at `/docs` holding `entries`.
@MainActor
private func loaded(
    _ entries: [DirectoryEntry], sortedBy column: SortColumn = .name, ascending: Bool = true
) async -> PaneFixture {
    let fixture = PaneFixture(
        at: "/docs", folders: ["/docs": entries], sortedBy: column, ascending: ascending)
    await settle { fixture.pane.state.isLoaded }
    return fixture
}

/// Types `text` into `typeSelect` and selects the first match in the fixture's pane, as the
/// list does for a key. Returns whether a row matched.
@MainActor
private func type(_ text: String, into typeSelect: inout TypeSelect, _ fixture: PaneFixture)
    -> Bool
{
    let query = typeSelect.type(text)
    return SelectionCommands.selectFirstRow(
        startingWith: query, in: CommandContext(pane: fixture.pane))
}

@MainActor
private func selected(_ name: String) -> Selection {
    Selection([ExactName(name)], cursor: ExactName(name))
}

private let documents = [
    file("readme", size: 10), file("Report.pdf", size: 500), file("Resume", size: 20),
    file("beta", size: 30),
]

@MainActor @Test func theFirstMatchInNameOrderIsSelected() async {
    let fixture = await loaded(documents)
    var typeSelect = TypeSelect(clock: ManualClock())

    #expect(type("r", into: &typeSelect, fixture))
    #expect(fixture.pane.selection == selected("readme"))
    #expect(type("e", into: &typeSelect, fixture))
    #expect(fixture.pane.selection == selected("readme"))
    #expect(type("p", into: &typeSelect, fixture))
    #expect(fixture.pane.selection == selected("Report.pdf"))
}

/// Largest first, "Report.pdf" comes before "readme", so "re" selects it.
@MainActor @Test func theFirstMatchInDisplayOrderIsSelectedSortedBySize() async {
    let fixture = await loaded(documents, sortedBy: .size, ascending: false)
    var typeSelect = TypeSelect(clock: ManualClock())

    #expect(type("re", into: &typeSelect, fixture))
    #expect(fixture.pane.selection == selected("Report.pdf"))
}

@MainActor @Test func anAccentedQueryMatchesTheUnaccentedName() async {
    let fixture = await loaded(documents)
    var typeSelect = TypeSelect(clock: ManualClock())

    #expect(type("r", into: &typeSelect, fixture))
    #expect(type("é", into: &typeSelect, fixture))
    #expect(type("s", into: &typeSelect, fixture))
    #expect(fixture.pane.selection == selected("Resume"))
}

/// The fold decomposes Hangul syllables into jamo, so 가 prefixes 각 only on the bytes.
@MainActor @Test func aHangulSyllablePrefixesTheSyllablesItStarts() async {
    let fixture = await loaded([file("aa"), file("각")])
    var typeSelect = TypeSelect(clock: ManualClock())

    #expect(type("가", into: &typeSelect, fixture))
    #expect(fixture.pane.selection == selected("각"))
}

@MainActor @Test func keysWithinTheResetIntervalAddToTheQuery() {
    let clock = ManualClock()
    var typeSelect = TypeSelect(clock: clock)

    #expect(typeSelect.type("r") == "r")
    clock.advance(by: .milliseconds(999))
    #expect(typeSelect.isTyping)
    #expect(typeSelect.type("e") == "re")
}

@MainActor @Test func aKeyAfterTheResetIntervalStartsANewQuery() async {
    let fixture = await loaded(documents)
    let clock = ManualClock()
    var typeSelect = TypeSelect(clock: clock)

    #expect(type("r", into: &typeSelect, fixture))
    clock.advance(by: TypeSelect.resetInterval)
    #expect(!typeSelect.isTyping)
    #expect(type("b", into: &typeSelect, fixture))

    #expect(typeSelect.query == "b")
    #expect(fixture.pane.selection == selected("beta"))
}

@MainActor @Test func noQueryIsTypingBeforeTheFirstKey() {
    #expect(!TypeSelect(clock: ManualClock()).isTyping)
}

@MainActor @Test func noMatchKeepsTheSelection() async {
    let fixture = await loaded(documents)
    var typeSelect = TypeSelect(clock: ManualClock())

    #expect(type("be", into: &typeSelect, fixture))
    #expect(!type("x", into: &typeSelect, fixture))

    #expect(typeSelect.query == "bex")
    #expect(fixture.pane.selection == selected("beta"))
}

/// Largest first, "myapp" comes before "my file", so only the space tells them apart.
@MainActor @Test func aSpaceAddedToTheQueryMatchesNamesWithASpace() async {
    let fixture = await loaded(
        [file("myapp", size: 9), file("my file", size: 1)], sortedBy: .size, ascending: false)
    var typeSelect = TypeSelect(clock: ManualClock())

    #expect(type("my", into: &typeSelect, fixture))
    #expect(fixture.pane.selection == selected("myapp"))
    #expect(type(" ", into: &typeSelect, fixture))
    #expect(fixture.pane.selection == selected("my file"))
}

/// Hidden files are off by default, so ".readme" and the flagged "aardvark" have no row.
@MainActor @Test func hiddenEntriesNeverMatch() async {
    let flagged = DirectoryEntry(
        name: "aardvark", type: .regular, size: 1, modified: testDate, isHidden: true,
        isDataless: false)
    let fixture = await loaded([file(".readme"), flagged, file("apple")])
    var typeSelect = TypeSelect(clock: ManualClock())

    #expect(type("a", into: &typeSelect, fixture))
    #expect(fixture.pane.selection == selected("apple"))
    #expect(!type(".", into: &typeSelect, fixture))
    #expect(TypeSelect.firstRow(startingWith: ".", in: fixture.pane.state.listing!) == nil)
}

@MainActor @Test func aKeyWithNoListingMatchesNothing() {
    let fixture = PaneFixture(at: "/docs", folders: ["/docs": documents], held: true)
    var typeSelect = TypeSelect(clock: ManualClock())

    #expect(!type("r", into: &typeSelect, fixture))
    fixture.lister.releaseAll()
}

@Test(
    arguments: [
        (KeyChord("r"), "r"), (KeyChord("r", modifiers: .shift), "r"),
        (KeyChord("!", modifiers: .shift), "!"), (KeyChord("é"), "é"),
    ] as [(KeyChord, String)])
func aPrintableKeyWithoutCommandControlOrOptionTypesItsCharacter(chord: KeyChord, text: String) {
    #expect(TypeSelect.text(for: chord) == text)
}

@Test(
    arguments: [
        KeyChord("r", modifiers: .command), KeyChord("r", modifiers: .control),
        KeyChord("r", modifiers: .option), KeyChord(.space), KeyChord(.down), KeyChord(.return),
        KeyChord(.tab),
    ])
func otherKeysTypeNothing(chord: KeyChord) {
    #expect(TypeSelect.text(for: chord) == nil)
}

@MainActor @Test func resetEndsTheQuery() {
    var typeSelect = TypeSelect(clock: ManualClock())
    _ = typeSelect.type("r")

    typeSelect.reset()

    #expect(!typeSelect.isTyping)
    #expect(typeSelect.query == "")
    #expect(typeSelect.type("b") == "b")
}
