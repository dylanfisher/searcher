import Foundation

/// What the app asks the system to do outside its own windows. Interface supplies the real one;
/// the pane never touches the workspace itself.
@MainActor
public protocol SystemActions: AnyObject {
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
}
