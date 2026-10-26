import Base
import Foundation
import TestSupport
import Testing

@testable import Browser

@MainActor @Test func theDefaultFavoritesAreFindersWithoutAirDropAndRecents() {
    #expect(
        Favorite.defaults(home: "/Users/u").map(\.path) == [
            "/Applications", "/Users/u/Desktop", "/Users/u/Documents", "/Users/u/Downloads",
            "/Users/u",
        ])
    #expect(Favorite.defaults(home: "/Users/u").allSatisfy { $0.bookmark == nil })
}

@MainActor @Test func aFavoriteReadsBackFromItsStoredShapeAndNothingElse() {
    let bookmark = Data([1, 2, 3])
    let favorite = Favorite(path: "/a/b", bookmark: bookmark)

    #expect(Favorite(stored: favorite.stored) == favorite)
    #expect(Favorite(stored: Favorite(path: "/a").stored) == Favorite(path: "/a"))
    let others: [Any] = [
        "/a", ["path": "a/b"], ["path": 1], ["bookmark": bookmark],
        ["path": "/a", "bookmark": "data"], ["path": "/a", "other": 1], [1, 2],
    ]
    for stored in others {
        #expect(Favorite(stored: stored) == nil, "\(stored)")
    }
}

@MainActor @Test func pathsInATrashAreInATrash() {
    #expect(Favorite.isInTrash("/Users/u/.Trash/a"))
    #expect(Favorite.isInTrash("/Volumes/X/.Trashes/501/a"))
    #expect(!Favorite.isInTrash("/Users/u/Trash/a"))
}

@Test func resolvingAFolderMakesItsBookmarkAndFollowsItWhenRenamed() async throws {
    let temp = try TemporaryFolder("FavoriteTests")
    let folder = temp.url.appending(path: "a")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)

    let first = await BlockingCallThread.run { Favorite.resolve(Favorite(path: folder.path)) }

    #expect(first.state == .folder)
    #expect(first.favorite.path == folder.path)
    let bookmarked = first.favorite
    #expect(bookmarked.bookmark != nil)

    let renamed = temp.url.appending(path: "b")
    try FileManager.default.moveItem(at: folder, to: renamed)
    let second = await BlockingCallThread.run { Favorite.resolve(bookmarked) }

    #expect(second.state == .folder)
    #expect(second.favorite.path == renamed.path)
}

@Test func aFileOrPackageResolvesAsAFileAndAGoneItemAsMissingUnchanged() async throws {
    let temp = try TemporaryFolder("FavoriteTests")
    let file = temp.url.appending(path: "a.txt")
    let package = temp.url.appending(path: "Tool.app")
    try Data().write(to: file)
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)

    let fileResolution = await BlockingCallThread.run {
        Favorite.resolve(Favorite(path: file.path))
    }
    let packageResolution = await BlockingCallThread.run {
        Favorite.resolve(Favorite(path: package.path))
    }

    #expect(fileResolution.state == .file)
    #expect(packageResolution.state == .file)
    let bookmarked = fileResolution.favorite
    try FileManager.default.removeItem(at: file)
    let gone = await BlockingCallThread.run { Favorite.resolve(bookmarked) }
    let neverThere = Favorite(path: temp.url.appending(path: "none").path)
    let missing = await BlockingCallThread.run { Favorite.resolve(neverThere) }

    #expect(gone == Favorite.Resolution(favorite: bookmarked, state: .missing))
    #expect(missing == Favorite.Resolution(favorite: neverThere, state: .missing))
}

@Test func aLinkToAFolderResolvesAsAFolderAtTheLinksPath() async throws {
    let temp = try TemporaryFolder("FavoriteTests")
    let folder = temp.url.appending(path: "target")
    let link = temp.url.appending(path: "link")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)

    let first = await BlockingCallThread.run { Favorite.resolve(Favorite(path: link.path)) }
    let bookmarked = first.favorite
    let again = await BlockingCallThread.run { Favorite.resolve(bookmarked) }

    #expect(first.state == .folder)
    #expect(first.favorite.path == link.path)
    #expect(again.state == .folder)
    #expect(again.favorite.path == link.path)
}

@Test func aFolderInTheTrashIsMissingUntilOneIsMadeAgainAtItsPath() async throws {
    let temp = try TemporaryFolder("FavoriteTests")
    let folder = temp.url.appending(path: "a")
    let trash = temp.url.appending(path: ".Trash")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false)
    let bookmarked = await BlockingCallThread.run { Favorite.resolve(Favorite(path: folder.path)) }
        .favorite
    try FileManager.default.moveItem(at: folder, to: trash.appending(path: "a"))

    let trashed = await BlockingCallThread.run { Favorite.resolve(bookmarked) }

    #expect(trashed == Favorite.Resolution(favorite: bookmarked, state: .missing))

    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    let remade = await BlockingCallThread.run { Favorite.resolve(bookmarked) }

    #expect(remade.state == .folder)
    #expect(remade.favorite.path == folder.path)
    let fresh = try #require(remade.favorite.bookmark)
    #expect(fresh != bookmarked.bookmark)
    // The new bookmark is the new folder's: it doesn't lead back into the Trash.
    let found = await BlockingCallThread.run { Favorite.resolve(remade.favorite) }
    #expect(found == Favorite.Resolution(favorite: remade.favorite, state: .folder))
}

@Test func aBookmarkThatDoesNotResolveFallsBackToThePathWithAFreshBookmark() async throws {
    let temp = try TemporaryFolder("FavoriteTests")
    let folder = temp.url.appending(path: "a")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    let dead = Favorite(path: folder.path, bookmark: Data([1, 2, 3]))

    let resolution = await BlockingCallThread.run { Favorite.resolve(dead) }

    #expect(resolution.state == .folder)
    #expect(resolution.favorite.path == folder.path)
    let fresh = try #require(resolution.favorite.bookmark)
    #expect(fresh != Data([1, 2, 3]))
}
