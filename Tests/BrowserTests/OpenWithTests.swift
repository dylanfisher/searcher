import Base
import BrowserTestSupport
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
    built: EventLog<UTType> = EventLog()
) -> (OpenWith, StubSystemActions) {
    let actions = StubSystemActions(
        applications: applications, defaultApplications: defaults, apps: apps)
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
        name: "Google Chrome for Testing.app", version: version, icon: stubAppIcon())
}

@MainActor @Test func eachAppCarriesTheNameVersionAndIconItWasReadWithOffTheMainActorOnce()
    async throws
{
    let chrome = chromeForTesting("153.0.8010.12")
    let (cache, actions) = openWith([.html: [chrome.url]], apps: [chrome])

    let first = await cache.choices(for: [.html])
    _ = await cache.choices(for: [.html])

    let app = try #require(first.others.first)
    #expect(app.name == "Google Chrome for Testing.app")
    #expect(app.version == "153.0.8010.12")
    #expect(app.icon === chrome.icon)
    #expect(cache.cachedChoices(for: [.html])?.others.first?.icon === chrome.icon)
    #expect(actions.appReads.all.map(\.url) == [chrome.url])
    #expect(actions.appReads.all.allSatisfy { !$0.onMainThread })
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
