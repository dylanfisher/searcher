import Base
import BrowserTestSupport
import Foundation
import TestSupport
import Testing

@testable import Browser

/// Finds each favorite as `states` says, by path, `.folder` for any other path, keeping its path
/// and giving it a bookmark of its path's bytes; and counts the finds.
private final class StubResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var storedStates: [String: Favorite.State] = [:]
    private var storedCount = 0

    var states: [String: Favorite.State] {
        get { lock.withLock { storedStates } }
        set { lock.withLock { storedStates = newValue } }
    }

    var count: Int { lock.withLock { storedCount } }

    func resolve(_ favorite: Favorite) -> Favorite.Resolution {
        lock.withLock {
            storedCount += 1
            return Favorite.Resolution(
                favorite: Favorite(path: favorite.path, bookmark: Data(favorite.path.utf8)),
                state: storedStates[favorite.path] ?? .folder)
        }
    }
}

/// Favorites over settings stored in a temporary folder, for the home folder `/Users/u`, found
/// by a stub.
@MainActor
private struct Fixture {
    let folder: TemporaryFolder
    let suite: String
    let settings: Settings
    let resolver = StubResolver()
    let favorites: Favorites

    init() throws {
        folder = try TemporaryFolder("FavoritesTests")
        suite = folder.url.appending(path: "preferences").path
        settings = Settings(
            defaults: try #require(UserDefaults(suiteName: suite)), home: "/Users/u",
            log: unexpectedSettingsLog)
        let resolver = resolver
        favorites = Favorites(settings: settings) { resolver.resolve($0) }
    }

    var paths: [String] { favorites.items.map(\.path) }

    /// The settings as a relaunch reads them.
    func relaunched() throws -> Settings {
        Settings(
            defaults: try #require(UserDefaults(suiteName: suite)), home: "/Users/u",
            log: unexpectedSettingsLog)
    }
}

private let defaultPaths = [
    "/Applications", "/Users/u/Desktop", "/Users/u/Documents", "/Users/u/Downloads", "/Users/u",
]

@MainActor @Test func favoritesStartAsFindersDefaultsUnlookedFor() throws {
    let fixture = try Fixture()

    #expect(fixture.paths == defaultPaths)
    #expect(fixture.favorites.items.allSatisfy { $0.state == .unknown })
    #expect(fixture.favorites.items.map(\.name).last == "u")
}

@MainActor @Test func insertingAddsAtTheIndexLeavesOutDuplicatesAndIsStored() async throws {
    let fixture = try Fixture()

    fixture.favorites.insert(["/p/new", "/users/U/desktop", "/p/new", "/p/other"], at: 1)

    #expect(
        fixture.paths == [
            "/Applications", "/p/new", "/p/other", "/Users/u/Desktop", "/Users/u/Documents",
            "/Users/u/Downloads", "/Users/u",
        ])
    #expect(try fixture.relaunched().favorites.map(\.path) == fixture.paths)
    // The added ones are looked for, and their bookmarks are stored.
    await settle { fixture.favorites.items[1].state == .folder }
    await settle { fixture.favorites.items[2].state == .folder }
    let stored = try fixture.relaunched().favorites
    #expect(stored[1] == Favorite(path: "/p/new", bookmark: Data("/p/new".utf8)))
    #expect(stored[0].bookmark == nil)

    fixture.favorites.insert(["/p/end"], at: 99)
    #expect(fixture.paths.last == "/p/end")
}

@MainActor @Test func movingAFavoriteReordersItEitherWay() throws {
    let fixture = try Fixture()

    // Before Downloads, which is at 3 before the move.
    fixture.favorites.move("/Applications", to: 3)
    #expect(
        fixture.paths == [
            "/Users/u/Desktop", "/Users/u/Documents", "/Applications", "/Users/u/Downloads",
            "/Users/u",
        ])

    fixture.favorites.move("/Users/u", to: 0)
    #expect(
        fixture.paths == [
            "/Users/u", "/Users/u/Desktop", "/Users/u/Documents", "/Applications",
            "/Users/u/Downloads",
        ])

    fixture.favorites.move("/Users/u", to: 5)
    #expect(fixture.paths.last == "/Users/u")
    #expect(try fixture.relaunched().favorites.map(\.path) == fixture.paths)
}

@MainActor @Test func removingAFavoriteIsStoredEvenDownToNone() throws {
    let fixture = try Fixture()

    fixture.favorites.remove("/Users/u/Documents")
    #expect(!fixture.paths.contains("/Users/u/Documents"))
    #expect(try fixture.relaunched().favorites.map(\.path) == fixture.paths)

    for path in fixture.paths {
        fixture.favorites.remove(path)
    }
    // An empty list is a list, not a missing one: the defaults don't come back.
    #expect(try fixture.relaunched().favorites.isEmpty)
}

@MainActor @Test func refreshFindsEachFavoriteAndMarksTheMissingOnes() async throws {
    let fixture = try Fixture()
    fixture.resolver.states = ["/Users/u/Downloads": .missing, "/Applications": .file]
    var changes = 0
    fixture.favorites.observe(for: fixture.settings) { changes += 1 }

    fixture.favorites.refresh()

    await settle { !fixture.favorites.items.contains { $0.state == .unknown } }
    #expect(
        fixture.favorites.items.map(\.state) == [.file, .folder, .folder, .missing, .folder])
    #expect(changes > 0)
    // A missing favorite stays in the list.
    #expect(fixture.paths == defaultPaths)
}

@MainActor @Test func aFavoriteFoundElsewhereTakesItsNewPathUnlessTheListHasIt() async throws {
    let fixture = try Fixture()
    let moved = Favorite.Resolution(
        favorite: Favorite(path: "/p/moved", bookmark: Data([1])), state: .folder)
    let onto = Favorite.Resolution(
        favorite: Favorite(path: "/Users/u", bookmark: Data([2])), state: .folder)
    let favorites = Favorites(settings: fixture.settings) { favorite in
        switch favorite.path {
        case "/Users/u/Desktop": moved
        case "/Users/u/Documents": onto
        default: Favorite.Resolution(favorite: favorite, state: .folder)
        }
    }

    favorites.refresh()

    await settle { !favorites.items.contains { $0.state == .unknown } }
    #expect(
        favorites.items.map(\.path) == [
            "/Applications", "/p/moved", "/Users/u/Downloads", "/Users/u",
        ])
}

@MainActor @Test func openingAFolderFavoriteShowsItInThePaneAndAFileOpensInItsApp() async throws {
    let fixture = try Fixture()
    fixture.resolver.states = ["/p/a.txt": .file, "/p/gone": .missing]
    let paneFixture = PaneFixture(
        at: "/r", folders: ["/r": [], "/Users/u/Documents": [file("x")]])
    let pane = paneFixture.pane
    fixture.favorites.insert(["/p/a.txt", "/p/gone"], at: 0)

    fixture.favorites.open("/Users/u/Documents") { pane }
    await settle { pane.location.path == "/Users/u/Documents" }

    fixture.favorites.open("/p/a.txt") { pane }
    await settle { !paneFixture.actions.openedFiles.isEmpty }
    #expect(paneFixture.actions.openedFiles.map(\.path) == ["/p/a.txt"])

    let finds = fixture.resolver.count
    fixture.favorites.open("/p/gone") { pane }
    await settle { fixture.resolver.count > finds }
    await settle { fixture.favorites.items[1].state == .missing }
    #expect(pane.location.path == "/Users/u/Documents")
    #expect(paneFixture.actions.openedFiles.count == 1)
}

@MainActor @Test func aFavoriteRenamedOnlyInCaseKeepsItsPlaceUnderTheNewName() async throws {
    let fixture = try Fixture()
    let favorites = Favorites(settings: fixture.settings) { favorite in
        guard favorite.path == "/Users/u/Documents" else {
            return Favorite.Resolution(favorite: favorite, state: .folder)
        }
        return Favorite.Resolution(
            favorite: Favorite(path: "/Users/u/documents", bookmark: Data([1])), state: .folder)
    }

    favorites.refresh()

    await settle { !favorites.items.contains { $0.state == .unknown } }
    #expect(
        favorites.items.map(\.path) == [
            "/Applications", "/Users/u/Desktop", "/Users/u/documents", "/Users/u/Downloads",
            "/Users/u",
        ])
}

/// Finds each favorite as `.folder` at its path, holding the finds of the paths in `held` until
/// the test releases them, each on its own thread; a released path isn't held again.
private final class HeldResolver: @unchecked Sendable {
    private let gates: [String: DispatchSemaphore]

    init(holding held: [String]) {
        gates = Dictionary(uniqueKeysWithValues: held.map { ($0, DispatchSemaphore(value: 0)) })
    }

    func release(_ path: String) {
        gates[path]?.signal()
    }

    func resolve(_ favorite: Favorite) -> Favorite.Resolution {
        if let gate = gates[favorite.path] {
            // Passed on, so a released path stays open for the finds after it.
            gate.wait()
            gate.signal()
        }
        return Favorite.Resolution(
            favorite: Favorite(path: favorite.path, bookmark: Data(favorite.path.utf8)),
            state: .folder)
    }
}

@MainActor @Test func onlyTheLatestOpenActsWhenAnEarlierOneIsFoundAfterIt() async throws {
    let fixture = try Fixture()
    let resolver = HeldResolver(holding: ["/Users/u/Desktop"])
    let favorites = Favorites(settings: fixture.settings) { resolver.resolve($0) }
    let pane = PaneFixture(
        at: "/r",
        folders: ["/r": [], "/Users/u/Desktop": [], "/Users/u/Documents": [file("x")]]
    ).pane

    favorites.open("/Users/u/Desktop") { pane }
    favorites.open("/Users/u/Documents") { pane }
    await settle { pane.location.path == "/Users/u/Documents" }
    resolver.release("/Users/u/Desktop")

    // The held find lands: Desktop is found, but its open was overtaken.
    await settle { favorites.items[1].state == .folder }
    #expect(pane.location.path == "/Users/u/Documents")
}

@MainActor @Test func aListChangedWhileItemsAreLookedForKeepsTheChange() async throws {
    let fixture = try Fixture()
    let resolver = HeldResolver(holding: ["/Users/u/Desktop", "/Users/u/Downloads"])
    let favorites = Favorites(settings: fixture.settings) { resolver.resolve($0) }
    favorites.refresh()
    await settle { favorites.resolving == ["/Users/u/Desktop", "/Users/u/Downloads"] }

    favorites.remove("/Users/u/Downloads")
    favorites.move("/Users/u/Desktop", to: 5)
    favorites.insert(["/p/new"], at: 0)
    resolver.release("/Users/u/Downloads")
    resolver.release("/Users/u/Desktop")
    await settle { favorites.resolving.isEmpty }

    let paths = ["/p/new", "/Applications", "/Users/u/Documents", "/Users/u", "/Users/u/Desktop"]
    #expect(favorites.items.map(\.path) == paths)
    #expect(favorites.items.allSatisfy { $0.state == .folder })
    #expect(try fixture.relaunched().favorites.map(\.path) == paths)
}

@MainActor @Test func aFavoriteRemovedAndAddedAgainWhileLookedForIsLookedForAgain() async throws {
    let fixture = try Fixture()
    let resolver = HeldResolver(holding: ["/Users/u/Desktop"])
    let favorites = Favorites(settings: fixture.settings) { resolver.resolve($0) }
    // Bookmarked, so the favorite added again, which has none yet, isn't the one looked for.
    fixture.settings.favorites[1] = Favorite(path: "/Users/u/Desktop", bookmark: Data([9]))
    favorites.refresh()
    await settle { favorites.resolving == ["/Users/u/Desktop"] }

    favorites.remove("/Users/u/Desktop")
    favorites.insert(["/Users/u/Desktop"], at: 1)
    resolver.release("/Users/u/Desktop")

    await settle { favorites.items[1].state == .folder }
    #expect(favorites.items.map(\.path) == defaultPaths)
    #expect(favorites.resolving.isEmpty)
}
