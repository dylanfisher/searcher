import AppKit
import Browser
import QuickLookThumbnailing
import UniformTypeIdentifiers
import os

/// `SystemActions` through `NSWorkspace` and the general pasteboard. Opening a file reads its type
/// and looks up its default app, which blocks on a slow share, so it runs off the main thread, as
/// listing the apps for a type does. Copying, revealing and opening files in a given app read no
/// file's type, and run on the main thread.
@MainActor
public final class WorkspaceSystemActions: SystemActions {
    /// No app on the Mac has the bundle ID a setting names.
    public struct AppNotFound: LocalizedError {
        public let bundleID: String

        public var errorDescription: String? {
            "There’s no app with the bundle ID “\(bundleID)”."
        }
    }

    private let logger = Logger(category: "workspace")
    /// The app with a bundle ID, or nil when there is none.
    private let applicationURL: @MainActor (String) -> URL?
    /// Shows the user an action that failed.
    private let presentError: @MainActor (any Error) -> Void

    public convenience init() {
        self.init(
            applicationURL: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
            presentError: { _ = NSApp.presentError($0) })
    }

    /// Tests pass a lookup that finds nothing and a `presentError` that records, so nothing opens
    /// and no alert shows.
    init(
        applicationURL: @escaping @MainActor (String) -> URL?,
        presentError: @escaping @MainActor (any Error) -> Void
    ) {
        self.applicationURL = applicationURL
        self.presentError = presentError
    }

    public func openFile(_ url: URL) {
        open(url)
    }

    public func openURL(_ url: URL) {
        open(url)
    }

    public func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if !pasteboard.setString(text, forType: .string) {
            logger.error("couldn't write \(text.count) characters to the pasteboard")
        }
    }

    public func revealInFinder(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    public func open(_ folder: URL, inAppWithBundleID bundleID: String) {
        guard let app = applicationURL(bundleID) else {
            fail(AppNotFound(bundleID: bundleID))
            return
        }
        NSWorkspace.shared.open(
            [folder], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()
        ) { _, error in
            guard let error else { return }
            Task { @MainActor in self.fail(error) }
        }
    }

    public func open(_ urls: [URL], withApplicationAt application: URL) {
        NSWorkspace.shared.open(
            urls, withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()
        ) { _, error in
            guard let error else { return }
            Task { @MainActor in self.fail(error) }
        }
    }

    public nonisolated func applicationURLs(toOpen type: UTType) -> [URL] {
        dispatchPrecondition(condition: .notOnQueue(.main))
        return NSWorkspace.shared.urlsForApplications(toOpen: type)
    }

    public nonisolated func defaultApplicationURL(toOpen type: UTType) -> URL? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        return NSWorkspace.shared.urlForApplication(toOpen: type)
    }

    /// Reads the app's bundle through Browser, logging an app with no readable bundle.
    public nonisolated func application(at url: URL) -> OpenWith.App {
        dispatchPrecondition(condition: .notOnQueue(.main))
        return OpenWith.App(readingBundleAt: url) { url in
            Logger(category: "openWith").error(
                "no readable bundle at \(url.path, privacy: .public); listed by its path")
        }
    }

    /// Asks Quick Look, which draws in its own process, for the icon Finder shows. An icon Quick
    /// Look can't make is logged and left out.
    public nonisolated func applicationIcon(at url: URL) async -> CGImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 16, height: 16), scale: 2,
            representationTypes: .icon)
        var icon: CGImage?
        do {
            icon = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
                .cgImage
        } catch {
            Logger(category: "openWith").error(
                "no icon for \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
        return icon
    }

    private func fail(_ error: any Error) {
        logger.error("\(error.localizedDescription, privacy: .public)")
        presentError(error)
    }

    private func open(_ url: URL) {
        let logger = logger
        DispatchQueue.global(qos: .userInitiated).async {
            if !NSWorkspace.shared.open(url) {
                logger.error("NSWorkspace couldn't open \(url.absoluteString, privacy: .public)")
            }
        }
    }
}
