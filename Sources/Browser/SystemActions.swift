import Foundation
import UniformTypeIdentifiers

/// What the app asks the system to do outside its own windows. Interface supplies the real one;
/// the pane never touches the workspace itself.
@MainActor
public protocol SystemActions: AnyObject, Sendable {
    /// Opens a file in its default app.
    func openFile(_ url: URL)
    func openURL(_ url: URL)
    /// Replaces what the general pasteboard holds with `text`.
    func copyToPasteboard(_ text: String)
    /// Shows `urls` selected in Finder.
    func revealInFinder(_ urls: [URL])
    /// Opens `folder` in the app with `bundleID`, or shows an error naming the bundle ID when no
    /// app on the Mac has it.
    func open(_ folder: URL, inAppWithBundleID bundleID: String)
    /// Opens `urls` in the app at `application`.
    func open(_ urls: [URL], withApplicationAt application: URL)
    /// The apps that can open a file of `type`, as Launch Services lists them. Asking Launch
    /// Services can block, so it is called off the main thread.
    nonisolated func applicationURLs(toOpen type: UTType) -> [URL]
    /// The app that opens a file of `type` by default, or nil when none does. Called off the main
    /// thread, as `applicationURLs(toOpen:)` is.
    nonisolated func defaultApplicationURL(toOpen type: UTType) -> URL?
}
