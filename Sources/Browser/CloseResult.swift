/// What a close took with it, so the caller knows whether to drop a pane's view, the tab or the
/// window.
public enum CloseResult: Equatable, Sendable {
    /// One pane closed; its tab still has others.
    case pane
    /// The tab's last pane closed, so the tab closed with it.
    case tab
    /// The workspace's last tab closed, so the workspace closed with it.
    case workspace
}
