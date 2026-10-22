import Foundation

/// What the app asks the system to do outside its own windows. Interface supplies the real one;
/// the pane never touches the workspace itself.
@MainActor
public protocol SystemActions: AnyObject {
    /// Opens a file in its default app.
    func openFile(_ url: URL)
    func openURL(_ url: URL)
}
