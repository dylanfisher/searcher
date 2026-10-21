import AppKit
import Browser
import os

/// `SystemActions` through `NSWorkspace`. Opening a file reads its type and looks up its default
/// app, which blocks on a slow share, so every call runs off the main thread.
@MainActor
public final class WorkspaceSystemActions: SystemActions {
    private let logger = Logger(category: "workspace")

    public init() {}

    public func openFile(_ url: URL) {
        open(url)
    }

    public func openURL(_ url: URL) {
        open(url)
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
