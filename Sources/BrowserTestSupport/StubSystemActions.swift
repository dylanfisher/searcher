import Browser
import CoreGraphics
import Foundation
import TestSupport
import UniformTypeIdentifiers

/// System actions that record what they were asked and open nothing.
@MainActor
public final class StubSystemActions: SystemActions {
    public private(set) var openedFiles: [URL] = []
    public private(set) var openedURLs: [URL] = []
    public private(set) var copiedTexts: [String] = []
    public private(set) var revealed: [[URL]] = []
    public private(set) var openedInApp: [OpenedInApp] = []
    public private(set) var openedWithApp: [OpenedWithApp] = []
    /// The apps listed for each type, and each type's default app.
    public nonisolated let applications: [UTType: [URL]]
    public nonisolated let defaultApplications: [UTType: URL]
    /// The apps read for their name, version and icon, by URL.
    public nonisolated let apps: [URL: OpenWith.App]
    /// Each type whose apps were listed, and whether that ran on the main thread.
    public nonisolated let lookups = EventLog<AppLookup>()
    /// Each app read, and whether that ran on the main thread.
    public nonisolated let appReads = EventLog<AppRead>()
    /// The icon of every app `apps` doesn't describe.
    public nonisolated let appIcon = stubAppIcon()

    /// An app listed in `applications` but not in `apps` is read as named for its file, without
    /// ".app", with that name as its bundle ID, no version and `appIcon`.
    public init(
        applications: [UTType: [URL]] = [:], defaultApplications: [UTType: URL] = [:],
        apps: [OpenWith.App] = []
    ) {
        self.applications = applications
        self.defaultApplications = defaultApplications
        self.apps = Dictionary(uniqueKeysWithValues: apps.map { ($0.url, $0) })
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
        return applications[type] ?? []
    }
    public nonisolated func defaultApplicationURL(toOpen type: UTType) -> URL? {
        defaultApplications[type]
    }
    public nonisolated func application(at url: URL) async -> OpenWith.App {
        appReads.append(AppRead(url: url, onMainThread: pthread_main_np() != 0))
        if let app = apps[url] { return app }
        let name = url.deletingPathExtension().lastPathComponent
        return OpenWith.App(url: url, bundleID: name, name: name, version: nil, icon: appIcon)
    }
}
