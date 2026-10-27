import Base
import BrowserTestSupport
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import Browser

private func file(_ name: String, size: Int64 = 0, modified: TimeInterval = 0) -> DirectoryEntry {
    DirectoryEntry(
        name: name, type: .regular, size: size, modified: Date(timeIntervalSince1970: modified),
        isHidden: false, isDataless: false)
}

private func folder(_ name: String, modified: TimeInterval = 0) -> DirectoryEntry {
    DirectoryEntry(
        name: name, type: .directory, size: nil, modified: Date(timeIntervalSince1970: modified),
        isHidden: false, isDataless: false)
}

private func package(_ name: String, modified: TimeInterval = 0) -> DirectoryEntry {
    DirectoryEntry(
        name: name, type: .package, size: nil, modified: Date(timeIntervalSince1970: modified),
        isHidden: false, isDataless: false)
}

/// Each row's folded name as bytes, since `String` equality treats canonically equivalent strings
/// as equal.
private func foldedNames(_ listing: Listing) -> [[UInt8]] {
    (0..<listing.count).map { Array(listing.foldedName(atRow: $0).utf8) }
}

private func sorted(_ entries: [DirectoryEntry], _ column: SortColumn, ascending: Bool = true)
    -> Listing
{
    var listing = Listing(entries)
    listing.sort(by: column, ascending: ascending, foldersFirst: false, showsHidden: true)
    return listing
}

private let everyOrder: [(SortColumn, Bool)] = SortColumn.allCases.flatMap { column in
    [(column, true), (column, false)]
}

@Test func sortsByNameInFinderOrder() {
    let entries = [file("b"), file("file10"), file("A"), file("file9"), folder("a folder")]
    #expect(names(sorted(entries, .name)) == ["A", "a folder", "b", "file9", "file10"])
    #expect(
        names(sorted(entries, .name, ascending: false)) == [
            "file10", "file9", "b", "a folder", "A",
        ])
}

@Test func namesWithOneKeyStillHaveOneOrder() {
    let forward = Listing([file("a"), file("A"), file("á")])
    let backward = Listing([file("á"), file("A"), file("a")])
    #expect(names(forward) == names(backward))
}

@Test func twoNamesWithOneKeyGoInByteOrder() {
    // Once with the run last in name order and once with a name after it.
    #expect(names(Listing([file("b"), file("B")])) == ["B", "b"])
    #expect(names(Listing([file("B"), file("b")])) == ["B", "b"])
    #expect(names(Listing([file("c"), file("b"), file("B")])) == ["B", "b", "c"])
    #expect(names(Listing([file("c"), file("B"), file("b")])) == ["B", "b", "c"])
}

@Test func sortsBySizeWithFoldersFirstAndTiesByName() {
    let entries = [
        file("big", size: 300), file("b", size: 100), file("a", size: 100), folder("z folder"),
        folder("folder"), file("empty", size: 0),
    ]
    #expect(
        names(sorted(entries, .size)) == ["folder", "z folder", "empty", "a", "b", "big"])
    #expect(
        names(sorted(entries, .size, ascending: false)) == [
            "big", "a", "b", "empty", "folder", "z folder",
        ])
}

@Test func sortsByDateModifiedWithTiesByName() {
    let entries = [
        file("new", modified: 300), file("y", modified: 100), file("x", modified: 100),
        folder("old", modified: 50),
    ]
    #expect(names(sorted(entries, .dateModified)) == ["old", "x", "y", "new"])
    #expect(names(sorted(entries, .dateModified, ascending: false)) == ["new", "x", "y", "old"])
}

@Test func sortsByKindWithTiesByName() {
    let entries = [
        file("song b.mp3"), file("photo.jpg"), folder("Music"), file("song a.MP3"),
        folder("Albums"),
    ]
    let listing = sorted(entries, .kind)
    let kindText = Dictionary(
        uniqueKeysWithValues: (0..<listing.count).map {
            (listing[$0].name, listing.kind(atRow: $0).text)
        })
    #expect(Set(kindText.values).count == 3)
    // Kind text is localized, so the expected order comes from the texts themselves.
    func expected(ascending: Bool) -> [String] {
        entries.map(\.name).sorted { a, b in
            let aKind = NameSortKey(kindText[a]!)
            let bKind = NameSortKey(kindText[b]!)
            if aKind != bKind {
                return ascending ? aKind < bKind : bKind < aKind
            }
            return NameSortKey(a) < NameSortKey(b)
        }
    }
    #expect(names(listing) == expected(ascending: true))
    #expect(names(sorted(entries, .kind, ascending: false)) == expected(ascending: false))
}

@Test func columnChangeReordersRowsNotEntries() {
    var listing = Listing([file("c", size: 1), file("a", size: 3), file("b", size: 2)])
    let entries = listing.entries
    let byName = names(listing)
    listing.sort(by: .size, ascending: true, foldersFirst: false, showsHidden: true)
    #expect(listing.entries == entries)
    #expect(names(listing) != byName)
    #expect(names(listing) == ["c", "b", "a"])
}

@Test func sortingOnTheMainThreadTraps() async {
    await #expect(processExitsWith: .failure) {
        let listing = Listing([file("c", size: 1), file("a", size: 3)])
        await MainActor.run {
            var listing = listing
            listing.sort(by: .size, ascending: true, foldersFirst: false, showsHidden: true)
        }
    }
}

@Test func twoFilesOfOneTypeGetOneKind() {
    let listing = Listing([file("a.mp3"), file("b.MP3"), file("c.jpg"), folder("d")])
    let kinds = (0..<listing.count).map { listing.kind(atRow: $0) }
    #expect(kinds[0] == kinds[1])
    #expect(kinds[0].text == kinds[1].text)
    #expect(kinds[0] != kinds[2])
    #expect(kinds[2] != kinds[3])
}

@Test func kindsAreLookedUpOncePerTypeAndExtension() {
    let entries = (0..<50).map { file("song \($0)" + ($0.isMultiple(of: 2) ? ".mp3" : ".MP3")) }
    let first = Listing(entries)
    let second = Listing(entries)
    #expect(first.kinds.count == 1)
    #expect(second.kinds.count == 1)
    #expect(EntryKind.typeLookupCount(.regular, pathExtension: "mp3") == 1)
    #expect(EntryKind.typeLookupCount(.regular, pathExtension: "MP3") == 1)
    #expect(EntryKind.descriptionCount(of: .mp3) == 1)
}

@Test func kindFollowsTypeAndExtension() throws {
    let listing = Listing([
        package("Mail.app"), folder("photos.jpg"), file("README"), folder("Kit.app"),
        package("Bundled"),
    ])
    func kind(_ name: String) throws -> UTType {
        listing.kind(atRow: try #require(listing.row(named: name))).type
    }
    #expect(try kind("Mail.app").conforms(to: .application))
    #expect(try kind("photos.jpg") == .folder)
    #expect(try kind("README") == .data)
    // The lister names packages, so a folder is a folder whatever its extension.
    #expect(try kind("Kit.app") == .folder)
    // A package by its bundle bit alone has no type of its own.
    #expect(try kind("Bundled") == .package)
    for row in 0..<listing.count {
        #expect(listing.kind(atRow: row).text.first?.isUppercase == true)
    }
}

/// Entries for patch tests: a spread of sizes, dates and kinds with ties in each column.
private let patchBase: [DirectoryEntry] = (0..<40).map { index in
    let name = "item \(index)" + [".mp3", ".jpg", ".txt", ""][index % 4]
    return index % 7 == 0
        ? folder(name, modified: TimeInterval(index % 5))
        : file(name, size: Int64(index % 6), modified: TimeInterval(index % 5))
}

@Test(arguments: SortColumn.allCases, [true, false])
func insertKeepsOrder(column: SortColumn, ascending: Bool) {
    var listing = sorted(patchBase, column, ascending: ascending)
    let new = [file("item 3b.mp3", size: 2, modified: 3), folder("Aardvark"), file("zz", size: 99)]
    for entry in new {
        listing.update(entry)
    }
    #expect(names(listing) == names(sorted(patchBase + new, column, ascending: ascending)))
    #expect(listing.count == patchBase.count + new.count)
}

@Test(arguments: SortColumn.allCases, [true, false])
func removeKeepsOrder(column: SortColumn, ascending: Bool) {
    var listing = sorted(patchBase, column, ascending: ascending)
    let removed = ["item 0.mp3", "item 17.jpg", "item 39"]
    for name in removed {
        #expect(listing.remove(named: name)?.name == name)
    }
    #expect(listing.remove(named: "not there") == nil)
    let rest = patchBase.filter { !removed.contains($0.name) }
    #expect(names(listing) == names(sorted(rest, column, ascending: ascending)))
    #expect(listing.entries.map(\.name).sorted() == rest.map(\.name).sorted())
}

@Test(arguments: SortColumn.allCases, [true, false])
func updateKeepsOrder(column: SortColumn, ascending: Bool) {
    var listing = sorted(patchBase, column, ascending: ascending)
    let changed = file("item 5.jpg", size: 1_000, modified: 1_000)
    listing.update(changed)
    var expected = patchBase
    expected[5] = changed
    #expect(names(listing) == names(sorted(expected, column, ascending: ascending)))
    #expect(listing.row(named: "item 5.jpg").map { listing[$0] } == changed)
    #expect(listing.count == patchBase.count)
}

@Test func randomPatchesMatchAFreshListing() {
    var generator = SystemRandomNumberGenerator()
    for (column, ascending) in everyOrder {
        var listing = sorted(patchBase, column, ascending: ascending)
        var current = Dictionary(uniqueKeysWithValues: patchBase.map { ($0.name, $0) })
        for step in 0..<200 {
            let name =
                Bool.random(using: &generator)
                ? patchBase.randomElement(using: &generator)!.name
                : "item \(Int.random(in: 0..<60, using: &generator))"
            if Bool.random(using: &generator) {
                #expect(listing.remove(named: name) == current.removeValue(forKey: name))
            } else {
                let entry = file(name, size: Int64(step % 9), modified: TimeInterval(step % 4))
                listing.update(entry)
                current[name] = entry
            }
        }
        let fresh = sorted(Array(current.values), column, ascending: ascending)
        #expect(names(listing) == names(fresh), "\(column) ascending: \(ascending)")
        #expect(
            (0..<listing.count).map { listing.kind(atRow: $0) }
                == (0..<fresh.count).map { fresh.kind(atRow: $0) })
        #expect(foldedNames(listing) == foldedNames(fresh))
    }
}

@Test func foldedNamesMatchTheFoldOfEachName() {
    // Enough entries that the build folds them in parallel chunks.
    let accented = ["Résumé", "ÜBER", "Ｆｉｌｅ", "plain", "Йогурт"]
    let entries = (0..<3_001).map { file("\(accented[$0 % accented.count]) \($0)") }
    var listing = Listing(entries)
    listing.update(file("Ünïcode Ｆｉｌｅ"))
    listing.remove(named: "plain 3")

    #expect(listing.count == entries.count)
    for row in 0..<listing.count {
        let expected = Array(NameSortKey.fold(listing[row].name).utf8)
        #expect(Array(listing.foldedName(atRow: row).utf8) == expected, "\(listing[row].name)")
    }
    #expect(listing.row(named: "Ünïcode Ｆｉｌｅ").map(listing.foldedName) == "unicode file")
}

@Test func rowNamedFindsTheRowInEveryOrder() {
    for (column, ascending) in everyOrder {
        let listing = sorted(patchBase, column, ascending: ascending)
        for row in 0..<listing.count {
            #expect(listing.row(named: listing[row].name) == row)
        }
        #expect(listing.row(named: "missing") == nil)
    }
}

@Test func namesNotInAnotherListingAreTheOnesItAdds() {
    // Composed and decomposed é have the same sort key and different bytes.
    let old = Listing([file("a"), file("b"), file("d"), file("\u{e9}")])
    let new = sorted(
        [file("e\u{301}"), file("d", size: 5), file("c"), file("a"), file("\u{e9}"), file("z")],
        .size)

    // Compared as bytes, since `String` equality treats the two é as one.
    #expect(
        Set(new.names(notIn: old).map { Array($0.utf8) })
            == Set(["c", "e\u{301}", "z"].map { Array($0.utf8) }))
    #expect(old.names(notIn: new) == ["b"])
    #expect(new.names(notIn: new).isEmpty)
}

// MARK: - Hidden entries and folders first

/// A file with the hidden flag, as `chflags hidden` sets it.
private func flagged(_ name: String, size: Int64 = 0, modified: TimeInterval = 0)
    -> DirectoryEntry
{
    DirectoryEntry(
        name: name, type: .regular, size: size, modified: Date(timeIntervalSince1970: modified),
        isHidden: true, isDataless: false)
}

private func arranged(
    _ entries: [DirectoryEntry], _ column: SortColumn, ascending: Bool, foldersFirst: Bool = false,
    showsHidden: Bool = true
) -> Listing {
    var listing = Listing(entries)
    listing.sort(
        by: column, ascending: ascending, foldersFirst: foldersFirst, showsHidden: showsHidden)
    return listing
}

/// Dot names and flagged entries, with ties and spreads in every column.
private let hiddenMix: [DirectoryEntry] = [
    file("b", size: 3, modified: 2), file(".profile", size: 9, modified: 1),
    flagged("flagged", size: 1, modified: 5), file("a.txt", size: 2, modified: 4),
    folder(".git", modified: 3), folder("docs", modified: 6), flagged("c", size: 3, modified: 2),
]
private let shownNames: Set = ["b", "a.txt", "docs"]

@Test func withHiddenOffDotAndFlaggedEntriesAreAbsentAndWithItOnTheyAreInSortOrder() {
    for (column, ascending) in everyOrder {
        let all = arranged(hiddenMix, column, ascending: ascending)
        let hidden = arranged(hiddenMix, column, ascending: ascending, showsHidden: false)

        #expect(Set(names(hidden)) == shownNames, "\(column) \(ascending)")
        #expect(names(hidden) == names(all).filter(shownNames.contains), "\(column) \(ascending)")
        #expect(all.count == hiddenMix.count)
        // Shown again, they're where a listing that never hid them has them.
        var shownAgain = hidden
        shownAgain.sort(by: column, ascending: ascending, foldersFirst: false, showsHidden: true)
        #expect(names(shownAgain) == names(all), "\(column) \(ascending)")
    }
    #expect(Set(names(Listing(hiddenMix, showsHidden: false))) == shownNames)
}

@Test func aHiddenEntryHasNoRowAndItsNearestRowIsTheNextShownOne() {
    let listing = Listing([file("a"), flagged("b"), file("c"), flagged("d")], showsHidden: false)

    #expect(names(listing) == ["a", "c"])
    #expect(listing.row(named: "b") == nil)
    #expect(listing.row(nearest: "b") == 1)
    #expect(listing.row(nearest: "a") == 0)
    // Nothing follows "d", so the last row is the nearest.
    #expect(listing.row(nearest: "d") == 1)
    #expect(listing.row(nearest: "not there") == nil)
    #expect(Listing([flagged("x")], showsHidden: false).row(nearest: "x") == nil)
}

@Test func namesNotInCountOnlyTheEntriesEachListingShows() {
    let hidden = Listing([file("a"), flagged("b"), file(".c")], showsHidden: false)
    var shown = hidden
    shown.sort(by: .name, ascending: true, foldersFirst: false, showsHidden: true)

    #expect(Set(shown.names(notIn: hidden)) == ["b", ".c"])
    #expect(hidden.names(notIn: shown).isEmpty)
}

/// `.DS_Store` by its exact name: other dot names, and names that only fold to it, keep their
/// rows when hidden entries show.
@Test func hidingDSStoreTakesItsRowEvenWhileHiddenEntriesShow() {
    let entries = [file("a"), file(".DS_Store"), file(".profile"), file(".DS_Store.txt")]
    for (column, ascending) in everyOrder {
        var listing = Listing(entries)
        listing.sort(
            by: column, ascending: ascending, foldersFirst: false, showsHidden: true,
            hidesDSStore: true)

        #expect(Set(names(listing)) == ["a", ".profile", ".DS_Store.txt"], "\(column)")
        #expect(listing.row(named: ".DS_Store") == nil)
        #expect(listing.hidesDSStore)

        var shown = listing
        shown.sort(
            by: column, ascending: ascending, foldersFirst: false, showsHidden: true,
            hidesDSStore: false)
        #expect(names(shown) == names(arranged(entries, column, ascending: ascending)))
        #expect(shown.names(notIn: listing) == [".DS_Store"])
    }
    let hidden = Listing(entries, showsHidden: false, hidesDSStore: true)
    #expect(names(hidden) == ["a"])
}

@Test func aDSStoreThatArrivesInAPatchGetsNoRowWhileItIsHidden() {
    var listing = Listing([file("a")], showsHidden: true, hidesDSStore: true)

    listing.update(file(".DS_Store"))

    #expect(names(listing) == ["a"])
    #expect(listing.entries.count == 2)
    #expect(listing.remove(named: ".DS_Store") != nil)
    #expect(names(listing) == ["a"])
}

@Test func foldersFirstPutsEveryFolderFirstForEachColumnAndDirection() {
    // "Mail.app" is a package, which Finder sorts with the files.
    let entries = [
        file("b", size: 5, modified: 3), folder("d", modified: 9), file("a", size: 1, modified: 1),
        folder("c", modified: 2), package("Mail.app", modified: 4), file("f", size: 9, modified: 5),
        folder("e", modified: 2),
    ]
    let folders: Set = ["c", "d", "e"]
    for (column, ascending) in everyOrder {
        let plain = names(arranged(entries, column, ascending: ascending))
        let first = names(arranged(entries, column, ascending: ascending, foldersFirst: true))

        let expected = plain.filter(folders.contains) + plain.filter { !folders.contains($0) }
        #expect(first == expected, "\(column) \(ascending)")
    }
}

@Test(arguments: SortColumn.allCases, [true, false])
func patchesKeepFoldersFirstAndHiddenEntriesOut(column: SortColumn, ascending: Bool) {
    var listing = arranged(
        patchBase, column, ascending: ascending, foldersFirst: true, showsHidden: false)
    let new = [
        folder("Aardvark"), flagged("item 3b.mp3", size: 2, modified: 3), file(".zz", size: 99),
        file("zz", size: 99), folder(".cache"),
    ]
    for entry in new {
        listing.update(entry)
    }
    listing.remove(named: "item 0.mp3")
    listing.remove(named: ".zz")
    // A shown entry that gains the hidden flag leaves the rows.
    let nowHidden = flagged("item 5.jpg", size: 5)
    listing.update(nowHidden)

    let expected = (patchBase + new)
        .filter { $0.name != "item 0.mp3" && $0.name != ".zz" }
        .map { $0.name == nowHidden.name ? nowHidden : $0 }
    let fresh = arranged(
        expected, column, ascending: ascending, foldersFirst: true, showsHidden: false)
    #expect(names(listing) == names(fresh))
    #expect(listing.row(named: nowHidden.name) == nil)

    listing.sort(by: column, ascending: ascending, foldersFirst: true, showsHidden: true)
    let shown = arranged(expected, column, ascending: ascending, foldersFirst: true)
    #expect(names(listing) == names(shown))
}

// MARK: - Folder sizes

private func walked(_ bytes: Int64, partial: Bool = false, modified: TimeInterval = 0)
    -> Listing.FolderSizeUpdate
{
    Listing.FolderSizeUpdate(
        modified: Date(timeIntervalSince1970: modified),
        value: .size(bytes: bytes, isPartial: partial))
}

/// `sizes` keyed by exact name, as the pane hands them over.
private func exact(_ sizes: [String: Listing.FolderSizeUpdate])
    -> [ExactName: Listing.FolderSizeUpdate]
{
    Dictionary(uniqueKeysWithValues: sizes.map { (ExactName($0.key), $0.value) })
}

private func folderSizes(_ listing: Listing) -> [Listing.FolderSizeValue?] {
    (0..<listing.count).map { listing.folderSize(atRow: $0) }
}

@Test func walkedFolderSizesSortWithTheFilesAndPendingFoldersStayBelowThem() {
    let entries = [file("big", size: 300), folder("a"), folder("b"), file("small", size: 10)]
    var listing = sorted(entries, .size, ascending: false)

    listing.applyFolderSizes(exact(["b": walked(1_000), "a": walked(50, partial: true)]))

    #expect(names(listing) == ["b", "big", "a", "small"])
    #expect(
        folderSizes(listing) == [
            .size(bytes: 1_000, isPartial: false), nil, .size(bytes: 50, isPartial: true), nil,
        ])

    var oneWalked = sorted(entries, .size, ascending: false)
    oneWalked.applyFolderSizes(exact(["a": walked(1_000)]))
    // "b" has no size yet, so it still sorts below a zero-byte file.
    #expect(names(oneWalked) == ["a", "big", "small", "b"])
}

@Test func aSizeWalkedAtAnotherFolderDateOrForAFileIsNotApplied() {
    var listing = Listing([folder("a", modified: 10), file("f", size: 5)])

    let changed = listing.applyFolderSizes(
        exact([
            "a": walked(1_000, modified: 20), "f": walked(1_000), "gone": walked(1),
        ]))

    #expect(!changed)
    #expect(folderSizes(listing) == [nil, nil])
}

@Test func aPatchKeepsAFoldersSizeUntilTheFoldersOwnDateChanges() {
    var listing = Listing([folder("a", modified: 10), folder("b", modified: 10)])
    listing.applyFolderSizes(exact(["a": walked(7, modified: 10), "b": walked(9, modified: 10)]))

    listing.update(folder("a", modified: 10))
    listing.update(folder("b", modified: 11))

    #expect(folderSizes(listing) == [.size(bytes: 7, isPartial: false), nil])
}

@Test func clearedFolderSizesSortAsPendingAgain() {
    var listing = sorted([folder("a"), file("f", size: 5)], .size, ascending: false)
    listing.applyFolderSizes(exact(["a": walked(1_000)]))
    #expect(names(listing) == ["a", "f"])

    listing.clearFolderSizes()

    #expect(names(listing) == ["f", "a"])
    #expect(folderSizes(listing) == [nil, nil])
}

@Test func aPackageTakesItsWalkedSizeAndKeepsItThroughAPatchAsAFolderDoes() {
    var listing = sorted([package("App.app", modified: 10), file("f", size: 5)], .size)

    listing.applyFolderSizes(exact(["App.app": walked(1_000, modified: 10)]))
    listing.update(package("App.app", modified: 10))

    #expect(names(listing) == ["f", "App.app"])
    #expect(folderSizes(listing) == [nil, .size(bytes: 1_000, isPartial: false)])
}

@Test func foldersFirstSortsPackagesWithTheFiles() {
    let entries = [package("Zed.app"), folder("b"), file("a.txt"), package("Bundled")]

    let listing = arranged(entries, .name, ascending: true, foldersFirst: true)

    #expect(names(listing) == ["b", "a.txt", "Bundled", "Zed.app"])
}

@Test func aFailedWalkIsKeptAsFailed() {
    var listing = Listing([folder("a")])

    listing.applyFolderSizes(
        exact([
            "a": Listing.FolderSizeUpdate(modified: Date(timeIntervalSince1970: 0), value: .failed)
        ]))

    #expect(folderSizes(listing) == [.failed])
}

@Test func canonicallyEqualFolderNamesGetTheirOwnSizes() {
    let composed = "Caf\u{E9}"
    let decomposed = "Cafe\u{301}"
    var listing = Listing([folder(composed), folder(decomposed)])

    listing.applyFolderSizes([ExactName(composed): walked(1), ExactName(decomposed): walked(2)])

    let sizes = Dictionary(
        uniqueKeysWithValues: (0..<2).map {
            (Array(listing[$0].name.utf8), listing.folderSize(atRow: $0))
        })
    #expect(sizes[Array(composed.utf8)] == .size(bytes: 1, isPartial: false))
    #expect(sizes[Array(decomposed.utf8)] == .size(bytes: 2, isPartial: false))
}
