import Browser
import CoreGraphics
import Foundation
import TestSupport
import UniformTypeIdentifiers
import os

/// System actions that record what they were asked and open nothing.
@MainActor
public final class StubSystemActions: SystemActions {
    public private(set) var openedFiles: [URL] = []
    public private(set) var openedURLs: [URL] = []
    public private(set) var copiedTexts: [String] = []
    public private(set) var revealed: [[URL]] = []
    public private(set) var openedInApp: [OpenedInApp] = []
    public private(set) var openedWithApp: [OpenedWithApp] = []
    /// The apps listed for each type, each type's default app, and the apps read for their name
    /// and version, by URL; `setApplications` changes them, as installing an app does.
    private nonisolated let installed: OSAllocatedUnfairLock<Installed>
    /// The apps' icons, by URL.
    public nonisolated let icons: [URL: CGImage]
    /// The apps whose icons are asked for and never come.
    public nonisolated let hangingIcons: Set<URL>
    /// Each type whose apps were listed, and whether that ran on the main thread.
    public nonisolated let lookups = EventLog<AppLookup>()
    /// Each app read, and each app whose icon was asked for, and whether that ran on the main
    /// thread.
    public nonisolated let appReads = EventLog<AppRead>()
    public nonisolated let iconReads = EventLog<AppRead>()
    /// The icon of every app `icons` doesn't name.
    public nonisolated let appIcon = stubAppIcon()

    /// An app listed in `applications` but not in `apps` is read as named for its file, without
    /// ".app", with that name as its bundle ID and no version.
    public init(
        applications: [UTType: [URL]] = [:], defaultApplications: [UTType: URL] = [:],
        apps: [OpenWith.App] = [], icons: [URL: CGImage] = [:], hangingIcons: Set<URL> = []
    ) {
        installed = OSAllocatedUnfairLock(
            initialState: Installed(
                applications: applications, defaultApplications: defaultApplications,
                apps: Dictionary(uniqueKeysWithValues: apps.map { ($0.url, $0) })))
        self.icons = icons
        self.hangingIcons = hangingIcons
    }

    /// Lists `applications` for each type from now on, as `init` takes them, so a test can
    /// install or remove an app between two lookups.
    public nonisolated func setApplications(
        _ applications: [UTType: [URL]], defaultApplications: [UTType: URL] = [:],
        apps: [OpenWith.App] = []
    ) {
        installed.withLock {
            $0 = Installed(
                applications: applications, defaultApplications: defaultApplications,
                apps: Dictionary(uniqueKeysWithValues: apps.map { ($0.url, $0) }))
        }
    }

    public func openFile(_ url: URL) { openedFiles.append(url) }
    public func openURL(_ url: URL) { openedURLs.append(url) }
    public func copyToPasteboard(_ text: String) { copiedTexts.append(text) }
    public func revealInFinder(_ urls: [URL]) { revealed.append(urls) }
    public func open(_ folder: URL, inAppWithBundleID bundleID: String) {
        openedInApp.append(OpenedInApp(folder: folder, bundleID: bundleID))
    }
    public func open(_ urls: [URL], withApplicationAt application: URL) {
        openedWithApp.append(OpenedWithApp(urls: urls, application: application))
    }
    public nonisolated func applicationURLs(toOpen type: UTType) -> [URL] {
        lookups.append(AppLookup(type: type, onMainThread: Thread.isMainThread))
        return installed.withLock { $0.applications[type] ?? [] }
    }
    public nonisolated func defaultApplicationURL(toOpen type: UTType) -> URL? {
        installed.withLock { $0.defaultApplications[type] }
    }
    public nonisolated func application(at url: URL) -> OpenWith.App {
        appReads.append(AppRead(url: url, onMainThread: Thread.isMainThread))
        if let app = installed.withLock({ $0.apps[url] }) { return app }
        let name = url.deletingPathExtension().lastPathComponent
        return OpenWith.App(url: url, bundleID: name, name: name, version: nil)
    }
    public nonisolated func applicationIcon(at url: URL) async -> CGImage? {
        iconReads.append(AppRead(url: url, onMainThread: pthread_main_np() != 0))
        if hangingIcons.contains(url) {
            while true {
                try? await Task.sleep(for: .seconds(3600))
            }
        }
        return icons[url] ?? appIcon
    }

    private struct Installed: Sendable {
        var applications: [UTType: [URL]]
        var defaultApplications: [UTType: URL]
        var apps: [URL: OpenWith.App]
    }
}
