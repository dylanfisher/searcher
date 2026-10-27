import Base
import BrowserTestSupport
import CoreGraphics
import Foundation
import TestSupport
import Testing
import UniformTypeIdentifiers

@testable import Browser

/// Paths the stub describes; nothing is read from them.
private let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
private let preview = URL(fileURLWithPath: "/System/Applications/Preview.app")
private let music = URL(fileURLWithPath: "/System/Applications/Music.app")
private let quickTime = URL(fileURLWithPath: "/System/Applications/QuickTime Player.app")

@MainActor
private func names(_ apps: [OpenWith.App]) -> [String] {
    apps.map(\.name)
}

/// An `OpenWith` over a stub listing `applications` for each type and describing `apps`, that
/// records each build.
@MainActor
private func openWith(
    _ applications: [UTType: [URL]], defaults: [UTType: URL] = [:], apps: [OpenWith.App] = [],
    icons: [URL: CGImage] = [:], hangingIcons: Set<URL> = [], built: EventLog<UTType> = EventLog()
) -> (OpenWith, StubSystemActions) {
    let actions = StubSystemActions(
        applications: applications, defaultApplications: defaults, apps: apps, icons: icons,
        hangingIcons: hangingIcons)
    return (OpenWith(systemActions: actions, didBuild: { type, _ in built.append(type) }), actions)
}

@MainActor @Test func oneTypeListsItsDefaultAppFirstThenTheRestByNameOncePerBundleID() async {
    // The same app twice, under a second spelling of its path.
    let textEditAgain = URL(fileURLWithPath: "/System/Applications/../Applications/TextEdit.app")
    let (cache, _) = openWith(
        [.plainText: [textEdit, quickTime, preview, textEditAgain]],
        defaults: [.plainText: preview])

    let choices = await cache.choices(for: [.plainText])

    #expect(choices.defaultApp?.name == "Preview")
    #expect(choices.defaultApp?.url == preview)
    #expect(names(choices.others) == ["QuickTime Player", "TextEdit"])
    #expect(names(choices.all) == ["Preview", "QuickTime Player", "TextEdit"])
}

@MainActor @Test func twoTypesListTheAppsThatOpenBoth() async {
    let (cache, _) = openWith(
        [.plainText: [textEdit, preview, music], .png: [preview, quickTime, textEdit]],
        defaults: [.plainText: textEdit, .png: textEdit])

    let choices = await cache.choices(for: [.plainText, .png])

    #expect(choices.defaultApp?.name == "TextEdit")
    #expect(names(choices.others) == ["Preview"])
}

@MainActor @Test func typesWithDifferentDefaultAppsListNoDefault() async {
    let (cache, _) = openWith(
        [.plainText: [textEdit, preview], .png: [preview, textEdit]],
        defaults: [.plainText: textEdit, .png: preview])

    let choices = await cache.choices(for: [.plainText, .png])

    #expect(choices.defaultApp == nil)
    #expect(names(choices.others) == ["Preview", "TextEdit"])
}

@MainActor @Test func eachTypesListIsBuiltOnceOffTheMainActor() async {
    let built = EventLog<UTType>()
    let (cache, actions) = openWith(
        [.plainText: [textEdit], .png: [preview]], defaults: [.plainText: textEdit], built: built)

    #expect(cache.cachedChoices(for: [.plainText]) == nil)
    _ = await cache.choices(for: [.plainText])
    _ = await cache.choices(for: [.plainText])
    _ = await cache.choices(for: [.plainText, .png])

    #expect(cache.cachedChoices(for: [.plainText])?.defaultApp?.name == "TextEdit")
    #expect(built.all.count == 2)
    #expect(Set(built.all) == [.plainText, .png])
    let lookups = actions.lookups.all
    #expect(lookups.filter { $0.type == .plainText }.count == 1)
    #expect(lookups.filter { $0.type == .png }.count == 1)
    #expect(lookups.allSatisfy { !$0.onMainThread })
}

@MainActor @Test func aPanesTypesAreTheKindsOfItsSelectedRows() async {
    let fixture = PaneFixture(
        at: "/types",
        folders: ["/types": [folder("docs"), file("a.txt"), file("b.png"), file("c.txt")]])
    await settle { fixture.pane.state.isLoaded }

    #expect(OpenWith.types(in: fixture.pane).isEmpty)
    fixture.select("a.txt", "c.txt")
    #expect(OpenWith.types(in: fixture.pane) == [.plainText])
    fixture.select("a.txt", "b.png", "docs")
    #expect(OpenWith.types(in: fixture.pane) == [.plainText, .png, .folder])
}

@MainActor @Test func choosingAnAppOpensTheSelectionWithIt() async {
    let fixture = await PaneFixture.loaded()
    fixture.select("a.txt", "b.txt")

    OpenWith.open(selectionOf: fixture.pane, withApplicationAt: textEdit)

    #expect(
        fixture.actions.openedWithApp == [
            OpenedWithApp(
                urls: [
                    URL(fileURLWithPath: "/root/a.txt", isDirectory: false),
                    URL(fileURLWithPath: "/root/b.txt", isDirectory: false),
                ],
                application: textEdit)
        ])
}

/// Copies of Google Chrome for Testing at three versions, as `@puppeteer/browsers` installs them,
/// each under its own folder.
private func chromeForTesting(_ version: String, in folder: String = "chrome") -> OpenWith.App {
    let url = URL(
        fileURLWithPath: "/Users/me/.cache/\(folder)/\(version)/Google Chrome for Testing.app",
        isDirectory: true)
    return OpenWith.App(
        url: url, bundleID: "com.google.chrome.for.testing",
        name: "Google Chrome for Testing.app", version: version)
}

@MainActor @Test func eachAppCarriesTheNameVersionAndIconItWasReadWithOffTheMainActorOnce()
    async throws
{
    let chrome = chromeForTesting("153.0.8010.12")
    let icon = stubAppIcon()
    let (cache, actions) = openWith(
        [.html: [chrome.url]], apps: [chrome], icons: [chrome.url: icon])

    let first = await cache.choices(for: [.html])
    _ = await cache.choices(for: [.html])

    let app = try #require(first.others.first)
    #expect(app.name == "Google Chrome for Testing.app")
    #expect(app.version == "153.0.8010.12")
    #expect(app.icon === icon)
    #expect(cache.cachedChoices(for: [.html])?.others.first?.icon === icon)
    for reads in [actions.appReads.all, actions.iconReads.all] {
        #expect(reads.map(\.url) == [chrome.url])
        #expect(reads.allSatisfy { !$0.onMainThread })
    }
}

@MainActor @Test func anIconThatNeverComesHoldsTheListBackOnlyForTheIconWait() async throws {
    let chrome = chromeForTesting("153.0.8010.12")
    let (cache, _) = openWith(
        [.html: [chrome.url, textEdit]], apps: [chrome], hangingIcons: [chrome.url])
    let clock = ManualClock()
    cache.clock = clock
    let building = Task { await cache.choices(for: [.html]) }
    await settle { clock.waitingSleeps == 1 }
    #expect(cache.cachedChoices(for: [.html]) == nil)

    clock.advance(by: cache.iconWait)
    let choices = await building.value

    #expect(names(choices.others) == ["Google Chrome for Testing.app", "TextEdit"])
    #expect(choices.others.map { $0.icon == nil } == [true, false])
    #expect(cache.cachedChoices(for: [.html]) == choices)
}

/// Icons that land within the wait end it, and its timer with it: only the list's rest is left
/// waiting on the clock.
@MainActor @Test func iconsThatLandStopTheIconWaitsTimer() async throws {
    let chrome = chromeForTesting("153.0.8010.12")
    let (cache, _) = openWith([.html: [chrome.url, textEdit]], apps: [chrome])
    let clock = ManualClock()
    cache.clock = clock

    _ = await cache.choices(for: [.html])
    await settle { clock.waitingSleeps == 1 && cache.resting.contains(.html) }
    await drainMainQueue()

    #expect(clock.waitingSleeps == 1)
    clock.advance(by: cache.refreshInterval)
    await settle { !cache.resting.contains(.html) }
    #expect(clock.waitingSleeps == 0)
}

@MainActor @Test func copiesOfAnAppAtDifferentVersionsAreEachListedAndShowTheirVersions() async {
    let old = chromeForTesting("151.0.7000.1")
    let current = chromeForTesting("152.0.7500.4")
    let new = chromeForTesting("153.0.8010.12")
    // A second copy of one version is listed once.
    let newAgain = chromeForTesting("153.0.8010.12", in: "other")
    let (cache, _) = openWith(
        [.html: [new.url, textEdit, old.url, newAgain.url, current.url]],
        defaults: [.html: current.url], apps: [old, current, new, newAgain])

    let choices = await cache.choices(for: [.html])

    #expect(choices.defaultApp?.url == current.url)
    #expect(choices.others.map(\.url) == [old.url, new.url, textEdit])
    #expect(choices.all.map { choices.showsVersion(of: $0) } == [true, true, true, false])
}

@MainActor @Test func appStoreSearchesTheStoreForTheSelectionsFileExtensions() async throws {
    let fixture = PaneFixture(
        at: "/types", folders: ["/types": [file("a.txt"), file("b.png"), file("c.txt")]])
    await settle { fixture.pane.state.isLoaded }
    fixture.select("a.txt", "b.png")

    OpenWith.searchAppStore(forSelectionOf: fixture.pane)

    #expect(
        fixture.actions.openedURLs == [
            try #require(URL(string: "macappstore://?action=search&term=png%20txt"))
        ])
}

// MARK: Refresh

@MainActor @Test func aRefreshListsTheTypeAgainOffTheMainActorAndReplacesTheCache() async {
    let (cache, actions) = openWith([.plainText: [textEdit]], defaults: [.plainText: textEdit])
    cache.refreshInterval = .zero
    _ = await cache.choices(for: [.plainText])
    await settle { !cache.resting.contains(.plainText) }
    actions.setApplications(
        [.plainText: [textEdit, preview]], defaultApplications: [.plainText: textEdit])

    cache.refresh([.plainText])

    // The cache answers at once, from the old list, until the new one lands.
    #expect(cache.cachedChoices(for: [.plainText])?.others == [])
    await settle { cache.cachedChoices(for: [.plainText])?.others.count == 1 }
    #expect(names(cache.cachedChoices(for: [.plainText])?.all ?? []) == ["TextEdit", "Preview"])
    #expect(names(await cache.choices(for: [.plainText]).others) == ["Preview"])
    #expect(actions.lookups.all.count == 2)
    #expect(actions.lookups.all.allSatisfy { !$0.onMainThread })
}

@MainActor @Test func aTypeIsRefreshedAtMostOnceARefreshInterval() async {
    let (cache, actions) = openWith([.plainText: [textEdit]])
    let clock = ManualClock()
    cache.clock = clock
    #expect(cache.refreshInterval == .seconds(5))
    _ = await cache.choices(for: [.plainText])
    await settle { clock.waitingSleeps == 1 }

    // The list just landed, so it stays for the interval.
    cache.refresh([.plainText])
    clock.advance(by: .seconds(4))
    cache.refresh([.plainText])
    #expect(actions.lookups.all.count == 1)

    clock.advance(by: .seconds(1))
    await settle { !cache.resting.contains(.plainText) }
    cache.refresh([.plainText])
    await settle { actions.lookups.all.count == 2 && cache.resting.contains(.plainText) }
    cache.refresh([.plainText])
    #expect(actions.lookups.all.count == 2)
}

/// Waits out `type`'s rest after its list landed, on `clock`, so `cache` refreshes it again.
@MainActor
private func endRest(of type: UTType, in cache: OpenWith, on clock: ManualClock) async {
    await settle { clock.waitingSleeps == 1 }
    clock.advance(by: cache.refreshInterval)
    await settle { !cache.resting.contains(type) }
}

@MainActor @Test func aTypeHasOneRefreshInFlightAndNoneBeforeItsFirstList() async {
    let (cache, actions) = openWith([.plainText: [textEdit]])
    let clock = ManualClock()
    cache.clock = clock

    // Nothing to refresh before the type's first list; the menu builds that one.
    cache.refresh([.plainText])
    #expect(actions.lookups.all.isEmpty)
    _ = await cache.choices(for: [.plainText])
    #expect(actions.lookups.all.count == 1)
    await endRest(of: .plainText, in: cache, on: clock)

    let held = heldQueue("OpenWithTests.held")
    cache.buildQueue = held
    cache.refresh([.plainText])
    cache.refresh([.plainText])
    cache.refresh([.plainText])
    held.resume()

    await settle { actions.lookups.all.count == 2 && cache.resting.contains(.plainText) }
    // A second refresh would have been queued behind the first on the held queue.
    held.sync {}
    #expect(actions.lookups.all.count == 2)
}

@MainActor @Test func aRefreshReusesTheIconsOfUnchangedAppsAndReadsANewVersionsIcon() async {
    let chrome = chromeForTesting("153.0.8010.12")
    let (cache, actions) = openWith([.html: [chrome.url, textEdit]], apps: [chrome])
    let clock = ManualClock()
    cache.clock = clock
    _ = await cache.choices(for: [.html])
    #expect(Set(actions.iconReads.all.map(\.url)) == [chrome.url, textEdit])

    // Same paths and versions: no icon is read again.
    await endRest(of: .html, in: cache, on: clock)
    cache.refresh([.html])
    await settle { actions.lookups.all.count == 2 && cache.resting.contains(.html) }
    #expect(actions.iconReads.all.count == 2)

    // Chrome updated in place: its icon is read again, TextEdit's isn't.
    let updated = OpenWith.App(
        url: chrome.url, bundleID: chrome.bundleID, name: chrome.name, version: "154.0.8100.2")
    actions.setApplications([.html: [chrome.url, textEdit]], apps: [updated])
    await endRest(of: .html, in: cache, on: clock)
    cache.refresh([.html])
    await settle { cache.cachedChoices(for: [.html])?.others.first?.version == "154.0.8100.2" }
    #expect(actions.iconReads.all.count == 3)
    #expect(actions.iconReads.all.last?.url == chrome.url)
    #expect(cache.cachedChoices(for: [.html])?.all.allSatisfy { $0.icon != nil } == true)
}
