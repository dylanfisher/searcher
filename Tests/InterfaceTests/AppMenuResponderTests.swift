import AppKit
import Browser
import BrowserTestSupport
import Foundation
import TestSupport
import Testing
import UniformTypeIdentifiers

@testable import Interface

/// The item in the real menu bar that runs `id`, the visible one.
@MainActor
private func menuItem(_ id: CommandID) throws -> NSMenuItem {
    let bar = try MainMenuBuilder.build(appName: "Searcher", registry: AppCommands.registry())
    func items(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) }
    }
    return try #require(
        items(bar).first { $0.representedObject as? CommandID == id && !$0.isHidden })
}

/// With no browser window's keys, as with only the Settings window open, App ▸ Open Config File
/// reaches the app's responder, which has it on and makes and opens the file.
@MainActor @Test func openConfigFileWithNoBrowserWindowOpensTheFile() async throws {
    let folder = try TemporaryFolder("AppMenuResponderTests")
    let file = folder.url.appending(path: "searcher/config")
    let settings = Settings(
        defaults: temporarySuite(in: folder.url.path), configFile: file,
        log: unexpectedSettingsLog)
    let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
    let actions = StubSystemActions(defaultApplications: [.plainText: textEdit])
    let responder = AppMenuResponder(
        settings: settings, systemActions: actions,
        openWindow: { Issue.record("a window opened") })
    let item = try menuItem(SystemCommands.openConfigFile.id)

    #expect(responder.validateMenuItem(item))
    #expect(NSApplication.shared.sendAction(try #require(item.action), to: responder, from: item))
    await settle { !actions.openedWithApp.isEmpty }

    #expect(actions.openedWithApp == [OpenedWithApp(urls: [file], application: textEdit)])
    #expect(try String(contentsOf: file, encoding: .utf8) == ConfigTemplate.text)
}

/// New Window opens a window; every other command's item is off without a browser window.
@MainActor @Test func newWindowWithNoBrowserWindowOpensOne() throws {
    var opened = 0
    let responder = AppMenuResponder(
        settings: untouchedSettings(), systemActions: StubSystemActions(),
        openWindow: { opened += 1 })
    let newWindow = try menuItem(WindowCommands.newWindow.id)

    #expect(responder.validateMenuItem(newWindow))
    #expect(
        NSApplication.shared.sendAction(
            try #require(newWindow.action), to: responder, from: newWindow))
    #expect(opened == 1)
    #expect(!responder.validateMenuItem(try menuItem(SystemCommands.copyPath.id)))
}

/// Settings with no config file leave Open Config File off.
@MainActor @Test func openConfigFileIsOffWithNoConfigFile() throws {
    let responder = AppMenuResponder(
        settings: untouchedSettings(), systemActions: StubSystemActions(), openWindow: {})

    #expect(!responder.validateMenuItem(try menuItem(SystemCommands.openConfigFile.id)))
}
