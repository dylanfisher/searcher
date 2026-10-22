import Base
import Foundation
import Testing

@testable import Browser

private func file(_ name: String, size: Int64 = 0, modified: TimeInterval = 0) -> DirectoryEntry {
    DirectoryEntry(
        name: name, type: .regular, size: size, modified: Date(timeIntervalSince1970: modified))
}

private func folder(_ name: String, modified: TimeInterval = 0) -> DirectoryEntry {
    DirectoryEntry(
        name: name, type: .directory, size: nil, modified: Date(timeIntervalSince1970: modified))
}

private func names(_ listing: Listing) -> [String] {
    (0..<listing.count).map { listing[$0].name }
}

private func sorted(_ entries: [DirectoryEntry], _ column: SortColumn, ascending: Bool = true)
    -> Listing
{
    var listing = Listing(entries)
    listing.sort(by: column, ascending: ascending)
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
    listing.sort(by: .size, ascending: true)
    #expect(listing.entries == entries)
    #expect(names(listing) != byName)
    #expect(names(listing) == ["c", "b", "a"])
}

@Test func sortingOnTheMainThreadTraps() async {
    await #expect(processExitsWith: .failure) {
        let listing = Listing([file("c", size: 1), file("a", size: 3)])
        await MainActor.run {
            var listing = listing
            listing.sort(by: .size, ascending: true)
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

@Test func kindFollowsTypeAndExtension() {
    let listing = Listing([folder("Mail.app"), folder("photos.jpg"), file("README")])
    #expect(listing.kind(atRow: 0).type.conforms(to: .application))
    #expect(listing.kind(atRow: 1).type == .folder)
    #expect(listing.kind(atRow: 2).type == .data)
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
    }
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
