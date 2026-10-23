import Base
import BrowserTestSupport
import Foundation
import TestSupport
import Testing
import UniformTypeIdentifiers

@testable import Browser

/// Apps every Mac has, so their bundle IDs and names can be read from the disk.
private let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
private let preview = URL(fileURLWithPath: "/System/Applications/Preview.app")
private let music = URL(fileURLWithPath: "/System/Applications/Music.app")
private let quickTime = URL(fileURLWithPath: "/System/Applications/QuickTime Player.app")

@MainActor
private func names(_ apps: [OpenWith.App]) -> [String] {
    apps.map(\.name)
}

/// An `OpenWith` over a stub listing `applications` for each type, that records each build.
@MainActor
private func openWith(
    _ applications: [UTType: [URL]], defaults: [UTType: URL] = [:],
    built: EventLog<UTType> = EventLog()
) -> (OpenWith, StubSystemActions) {
    let actions = StubSystemActions(applications: applications, defaultApplications: defaults)
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
    #expect(choices.defaultApp?.bundleID == "com.apple.Preview")
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
