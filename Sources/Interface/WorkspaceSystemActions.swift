import AppKit
import Base
import Browser
import QuickLookThumbnailing
import UniformTypeIdentifiers
import os

/// `SystemActions` through `NSWorkspace`, the general pasteboard and Apple Events to Finder.
/// Opening a file reads its type and looks up its default app, which blocks on a slow share, so it
/// runs off the main thread, as listing the apps for a type does. Get Info waits for Finder's
/// reply, so it runs off the main thread too. Copying, revealing and opening files in a given app
/// read no file's type, and run on the main thread.
@MainActor
public final class WorkspaceSystemActions: SystemActions {
    /// No app on the Mac has the bundle ID a setting names.
    public struct AppNotFound: LocalizedError {
        public let bundleID: String

        public var errorDescription: String? {
            "There’s no app with the bundle ID “\(bundleID)”."
        }
    }

    /// macOS refused to let the app send Finder Apple Events: the user turned it down in the
    /// Automation prompt, or turned it off in System Settings since. The alert's first button
    /// opens the Automation list, as `AccessDeniedView` opens the Full Disk Access one.
    public struct AutomationDenied: LocalizedError, RecoverableError {
        /// The Automation pane of Privacy & Security.
        static let automationSettings = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
        static let buttonTitle = "Open Automation Settings"

        /// Opens a URL, for the Automation list.
        let openURL: @Sendable (URL) -> Void

        public var errorDescription: String? {
            "Searcher can’t show Finder’s Info window"
        }

        public var recoverySuggestion: String? {
            "macOS lets Searcher ask Finder for Info windows only with Automation permission. "
                + "Turn on Finder under Searcher in the Automation list."
        }

        public var recoveryOptions: [String] { [Self.buttonTitle, "OK"] }

        public func attemptRecovery(optionIndex recoveryOptionIndex: Int) -> Bool {
            guard recoveryOptionIndex == 0 else { return false }
            openURL(Self.automationSettings)
            return true
        }
    }

    /// Finder didn't open the Info windows for another reason: it didn't answer in
    /// `finderTimeout`, or an item is gone.
    public struct InfoFailed: LocalizedError {
        public let reason: String

        public var errorDescription: String? {
            "Finder didn’t show the Info window"
        }

        public var recoverySuggestion: String? { reason }
    }

    /// How long Get Info waits for Finder's reply. The wait is off the main thread; a busy
    /// Finder that answers later still opens the windows.
    nonisolated static let finderTimeout: TimeInterval = 30
    /// The Apple Event errors that mean macOS refused the event: `errAEEventNotPermitted` and
    /// `errAEEventWouldRequireUserConsent`.
    nonisolated static let automationDeniedCodes: Set<Int> = [-1743, -1744]

    private let logger = Logger(category: "workspace")
    /// The app with a bundle ID, or nil when there is none.
    private let applicationURL: @MainActor (String) -> URL?
    /// Shows the user an action that failed.
    private let presentError: @MainActor (any Error) -> Void

    /// Asks Finder to open the Info windows of some items, waiting for its reply. Called off the
    /// main thread.
    private let sendToFinder: @Sendable ([URL]) throws -> Void
    /// Opens a URL, for the Automation list.
    private let openURL: @Sendable (URL) -> Void

    public convenience init() {
        self.init(
            applicationURL: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
            presentError: { _ = NSApp.presentError($0) },
            sendToFinder: Self.openInfoWindows,
            openURL: { url in
                if !NSWorkspace.shared.open(url) {
                    Logger(category: "workspace").error(
                        "NSWorkspace couldn't open \(url.absoluteString, privacy: .public)")
                }
            })
    }

    /// Tests pass a lookup that finds nothing and a `presentError` that records, so nothing opens
    /// and no alert shows, and a `sendToFinder` that records, since a test never sends Finder an
    /// Apple Event.
    init(
        applicationURL: @escaping @MainActor (String) -> URL?,
        presentError: @escaping @MainActor (any Error) -> Void,
        sendToFinder: @escaping @Sendable ([URL]) throws -> Void = { urls in
            preconditionFailure("a test asked Finder for the Info windows of \(urls)")
        },
        openURL: @escaping @Sendable (URL) -> Void = { url in
            preconditionFailure("a test asked to open \(url)")
        }
    ) {
        self.applicationURL = applicationURL
        self.presentError = presentError
        self.sendToFinder = sendToFinder
        self.openURL = openURL
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

    /// Sends Finder one event for every item, on a thread of its own, since Finder can take its
    /// time to answer and macOS holds the first event while it asks the user for Automation
    /// permission. A refusal is presented as `AutomationDenied`, any other failure as
    /// `InfoFailed`.
    public func showInfo(_ urls: [URL]) {
        let send = sendToFinder
        let openURL = openURL
        BlockingCallThread.start {
            do {
                try send(urls)
            } catch {
                let failure: any Error =
                    Self.automationDeniedCodes.contains((error as NSError).code)
                    ? AutomationDenied(openURL: openURL)
                    : InfoFailed(reason: error.localizedDescription)
                Task { @MainActor in self.fail(failure) }
            }
        }
    }

    /// Finder's Get Info for `urls`: one `open` of the `information window` of each item, as
    /// AppleScript sends `open information window of item`, then `activate`, so the windows come
    /// to the front.
    nonisolated static func infoEvent(for urls: [URL]) -> NSAppleEventDescriptor {
        let windows = NSAppleEventDescriptor.list()
        for (index, url) in urls.enumerated() {
            // An object specifier: the `iwnd` property of the item at the file URL.
            guard
                let window = NSAppleEventDescriptor.record().coerce(
                    toDescriptorType: DescType(typeObjectSpecifier))
            else {
                preconditionFailure("an Apple Event record didn't coerce to an object specifier")
            }
            window.setDescriptor(
                NSAppleEventDescriptor(typeCode: DescType(cProperty)),
                forKeyword: AEKeyword(keyAEDesiredClass))
            window.setDescriptor(
                NSAppleEventDescriptor(enumCode: DescType(formPropertyID)),
                forKeyword: AEKeyword(keyAEKeyForm))
            window.setDescriptor(
                NSAppleEventDescriptor(typeCode: informationWindow),
                forKeyword: AEKeyword(keyAEKeyData))
            window.setDescriptor(
                NSAppleEventDescriptor(fileURL: url), forKeyword: AEKeyword(keyAEContainer))
            windows.insert(window, at: index + 1)
        }
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenDocuments),
            targetDescriptor: finder(), returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(windows, forKeyword: AEKeyword(keyDirectObject))
        return event
    }

    /// Finder's `activate`, with no window named, which brings Finder to the front.
    nonisolated static func activateEvent() -> NSAppleEventDescriptor {
        NSAppleEventDescriptor.appleEvent(
            withEventClass: AEEventClass(kAEMiscStandards), eventID: AEEventID(kAEActivate),
            targetDescriptor: finder(), returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
    }

    private nonisolated static func finder() -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
    }
    /// Finder's `information window` property of an item, from its scripting dictionary.
    nonisolated static let informationWindow: DescType = 0x6977_6E64  // 'iwnd'

    /// Sends `infoEvent` and then `activateEvent` and waits for each reply, throwing the error
    /// Apple Events or Finder's reply gives.
    private nonisolated static func openInfoWindows(_ urls: [URL]) throws {
        dispatchPrecondition(condition: .notOnQueue(.main))
        for event in [infoEvent(for: urls), activateEvent()] {
            let reply = try event.sendEvent(
                options: [.waitForReply, .canInteract], timeout: finderTimeout)
            let code = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value ?? 0
            if code != 0 {
                let message = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorString))?
                    .stringValue
                throw NSError(
                    domain: NSOSStatusErrorDomain, code: Int(code),
                    userInfo: message.map { [NSLocalizedDescriptionKey: $0] } ?? [:])
            }
        }
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
