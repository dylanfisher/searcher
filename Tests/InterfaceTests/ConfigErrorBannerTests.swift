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

/// A file with an error shows a banner under the toolbar, over the tabs and the panes, that
/// names its line, and a good file takes it away. The rows start below the banner while it shows
/// (docs/decisions/0133-flat-translucent-bars.md).
@MainActor @Test func aConfigErrorShowsABannerUntilAGoodFileLoads() async throws {
    let config = try await ConfigFixture("ConfigErrorBannerTests")
    let controller = try await window(settings: config.settings)
    let banner = controller.configBanner
    let window = try #require(controller.window)
    let content = try #require(window.contentView)
    let pane = controller.paneViewController
    let table = pane.listingViewController.tableView
    let firstRow = { table.convert(table.rect(ofRow: 0), to: nil) }
    let toolbarBottom = window.contentLayoutRect.maxY
    #expect(banner.isHidden)

    try config.save("{\n  \"show-hidden\": true,\n  \"folders-first\": yes\n}")
    await settle { !banner.isHidden }
    content.layoutSubtreeIfNeeded()

    #expect(banner.message.stringValue.hasPrefix("Config file line 3: isn't valid JSON"))
    #expect(
        banner.message.stringValue.hasSuffix(
            "Until it's fixed, Searcher keeps its settings as they are and can't save changes"
                + " to the file."))
    let shown = banner.convert(banner.bounds, to: nil)
    #expect(shown.height > 0)
    #expect(shown.maxY <= toolbarBottom + 0.5)
    let underBanner = firstRow()
    #expect(underBanner.maxY <= shown.minY + 0.5)

    try config.save(#"{"show-hidden": true}"#)
    await settle { banner.isHidden }
    content.layoutSubtreeIfNeeded()

    // Up by the banner's height, under the toolbar.
    #expect(abs(firstRow().maxY - (underBanner.maxY + shown.height)) <= 0.5)
    #expect(firstRow().maxY <= toolbarBottom + 0.5)
    if #available(macOS 26, *) {
        #expect(pane.topCover == content.bounds.height - toolbarBottom)
    }
}

/// Several errors show the first and say how many more the file has; the tooltip lists them.
@MainActor @Test func theBannerCountsTheOtherErrors() async throws {
    let config = try await ConfigFixture("ConfigErrorBannerTests")
    let controller = try await window(settings: config.settings)

    try config.save(#"{"a": 1, "b": 2, "c": 3}"#)
    await settle { !controller.configBanner.isHidden }

    let message = controller.configBanner.message
    #expect(message.stringValue.hasPrefix(#"Config file unknown key "a"."#))
    #expect(message.stringValue.hasSuffix("The file has 2 more errors."))
    #expect(message.toolTip?.split(separator: "\n").count == 3)
}

/// The banner's button opens the config file, as Open Config File does, and leaves its bytes;
/// with no config file, as in the tests' and the bench's settings, it has none.
@MainActor @Test func theBannersButtonOpensTheConfigFile() async throws {
    let bytes = #"{"folders-first": "yes"}"#
    let config = try await ConfigFixture("ConfigErrorBannerTests", text: bytes)
    let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
    let actions = StubSystemActions(defaultApplications: [.plainText: textEdit])
    let controller = try await window(settings: config.settings, actions: actions)
    #expect(!controller.configBanner.isHidden)
    #expect(!controller.configBanner.openButton.isHidden)

    controller.configBanner.openButton.performClick(nil)
    await settle { !actions.openedWithApp.isEmpty }

    #expect(actions.openedWithApp == [OpenedWithApp(urls: [config.file], application: textEdit)])
    #expect(try String(contentsOf: config.file, encoding: .utf8) == bytes)

    let untouched = try await window(settings: untouchedSettings())
    #expect(untouched.configBanner.openButton.isHidden)
}
