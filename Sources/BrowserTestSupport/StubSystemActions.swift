import Browser
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
    /// Each type whose apps were listed, and whether that ran on the main thread.
    public nonisolated let lookups = EventLog<AppLookup>()

    public init(
        applications: [UTType: [URL]] = [:], defaultApplications: [UTType: URL] = [:]
    ) {
        self.applications = applications
        self.defaultApplications = defaultApplications
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
}
