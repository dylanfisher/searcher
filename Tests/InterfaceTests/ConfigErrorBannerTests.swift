import AppKit
import Browser
import BrowserTestSupport
import Foundation
import TestSupport
import Testing
import UniformTypeIdentifiers

@testable import Interface

/// A browser window at `/root` over `settings`, never shown, laid out.
@MainActor
private func window(settings: Settings, actions: StubSystemActions = StubSystemActions())
    async
    throws -> BrowserWindowController
{
    let controller = BrowserWindowController(
        location: Location(path: "/root"),
        service: ListingService(lister: StubLister(["/root": [file("a.txt")]])) { "Test Disk" },
        systemActions: actions, settings: settings, favorites: Favorites(settings: settings),
        volumes: StubSidebarVolumes().list())
    let window = try #require(controller.window)
    window.contentView?.layoutSubtreeIfNeeded()
    let workspace = controller.workspace
    await settle { workspace.selectedTab.focusedPane.state.isLoaded }
    return controller
}

/// A file with an error shows a banner over the tabs that names its line, and a good file
/// takes it away.
@MainActor @Test func aConfigErrorShowsABannerUntilAGoodFileLoads() async throws {
    let settings = untouchedSettings()
    let controller = try await window(settings: settings)
    let banner = controller.configBanner
    let content = try #require(banner.superview)
    #expect(banner.isHidden)

    settings.applyConfig(ConfigParser.parse("show-hidden = true\nfolders-first = yes"))
    content.layoutSubtreeIfNeeded()

    #expect(!banner.isHidden)
    #expect(
        banner.message.stringValue
            == #"Config file line 2: folders-first must be true or false, not "yes". "#
            + "Searcher keeps the settings it had until the file is fixed.")
    #expect(banner.frame.height > 0)
    #expect(controller.tabStrip.view.frame.maxY <= banner.frame.minY)

    settings.applyConfig(ConfigParser.parse("show-hidden = true"))
    content.layoutSubtreeIfNeeded()

    #expect(banner.isHidden)
    #expect(controller.tabStrip.view.frame.maxY == content.bounds.maxY)
}

/// Several errors show the first and say how many more the file has; the tooltip lists them.
@MainActor @Test func theBannerCountsTheOtherErrors() async throws {
    let settings = untouchedSettings()
    let controller = try await window(settings: settings)

    settings.applyConfig(ConfigParser.parse("a = 1\nb = 2\nc = 3"))

    let message = controller.configBanner.message
    #expect(message.stringValue.hasPrefix(#"Config file line 1: unknown key "a"."#))
    #expect(message.stringValue.hasSuffix("The file has 2 more errors."))
    #expect(message.toolTip?.split(separator: "\n").count == 3)
}

/// The banner's button opens the config file, as Open Config File does; with no config file,
/// as in the tests' and the bench's settings, it has none.
@MainActor @Test func theBannersButtonOpensTheConfigFile() async throws {
    let folder = try TemporaryFolder("ConfigErrorBannerTests")
    let file = folder.url.appending(path: "config")
    let bytes = Data("folders-first = yes\n".utf8)
    try bytes.write(to: file)
    let settings = Settings(
        defaults: temporarySuite(in: folder.url.path), configFile: file,
        log: unexpectedSettingsLog)
    let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
    let actions = StubSystemActions(defaultApplications: [.plainText: textEdit])
    let controller = try await window(settings: settings, actions: actions)
    settings.applyConfig(ConfigParser.parse(String(decoding: bytes, as: UTF8.self)))
    #expect(!controller.configBanner.openButton.isHidden)

    controller.configBanner.openButton.performClick(nil)
    await settle { !actions.openedWithApp.isEmpty }

    #expect(actions.openedWithApp == [OpenedWithApp(urls: [file], application: textEdit)])
    #expect(try Data(contentsOf: file) == bytes)

    let untouched = try await window(settings: untouchedSettings())
    #expect(untouched.configBanner.openButton.isHidden)
}
