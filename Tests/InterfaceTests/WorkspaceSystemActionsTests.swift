import AppKit
import Browser
import Foundation
import TestSupport
import Testing
import UniformTypeIdentifiers

@testable import Interface

/// The errors a `WorkspaceSystemActions` presented.
@MainActor
private final class ErrorLog {
    var errors: [any Error] = []
}

/// The lookup finds no app, so nothing is opened, and the error is recorded instead of shown.
@MainActor @Test func aBundleIDWithNoInstalledAppFailsWithAnErrorNamingIt() {
    let log = ErrorLog()
    let actions = WorkspaceSystemActions(
        applicationURL: { _ in nil }, presentError: { log.errors.append($0) })

    actions.open(
        URL(fileURLWithPath: "/tmp", isDirectory: true), inAppWithBundleID: "com.example.missing")

    #expect(log.errors.count == 1)
    #expect(log.errors.first?.localizedDescription.contains("com.example.missing") == true)
}

/// Open With lists what Launch Services lists for a file of the type, once per app, the default
/// first. Nothing is opened.
@MainActor @Test(arguments: ["txt", "png", "mp3"])
func openWithListsTheAppsLaunchServicesListsForAFileDefaultFirst(pathExtension: String)
    async throws
{
    let folder = try TemporaryFolder("OpenWith")
    let file = folder.url.appending(path: "sample.\(pathExtension)")
    try Data().write(to: file)
    let type = try #require(UTType(filenameExtension: pathExtension))
    let actions = WorkspaceSystemActions(applicationURL: { _ in nil }, presentError: { _ in })
    let cache = OpenWith(systemActions: actions, didBuild: { _, _ in })

    let choices = await cache.choices(for: [type])

    let listed = NSWorkspace.shared.urlsForApplications(toOpen: file)
    let defaultApp = try #require(NSWorkspace.shared.urlForApplication(toOpen: file))
    // One entry per bundle ID and version: copies of one version are listed once.
    let listedApps = Set(
        listed.map { url in
            let bundle = Bundle(url: url)
            return [
                bundle?.bundleIdentifier ?? url.path,
                bundle?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            ]
        })
    let chosen = choices.all.map { [$0.bundleID, $0.version ?? ""] }
    #expect(Set(chosen) == listedApps)
    #expect(chosen.count == listedApps.count)
    #expect(choices.defaultApp?.bundleID == Bundle(url: defaultApp)?.bundleIdentifier)
    #expect(choices.all.first == choices.defaultApp)
}

/// An app is read with the name Finder shows for it, its bundle ID and version, and its icon at
/// 16 points, 2x, off the main thread.
@MainActor @Test func anAppIsReadWithItsDisplayNameBundleIDVersionAndIcon() async throws {
    let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app", isDirectory: true)
    let actions = WorkspaceSystemActions(applicationURL: { _ in nil }, presentError: { _ in })

    let app = await actions.application(at: textEdit)

    let bundle = try #require(Bundle(url: textEdit))
    #expect(app.url == textEdit)
    #expect(app.name == FileManager.default.displayName(atPath: textEdit.path))
    #expect(app.bundleID == bundle.bundleIdentifier)
    #expect(app.version == bundle.infoDictionary?["CFBundleShortVersionString"] as? String)
    #expect(app.icon?.width == 32)
    #expect(app.icon?.height == 32)
}
