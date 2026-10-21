import AppKit
import Browser
import Interface
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let service = ListingService()
    private let systemActions = WorkspaceSystemActions()
    private var windows: [BrowserWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = BrowserWindowController(
            location: Location(path: NSHomeDirectory()), service: service,
            systemActions: systemActions)
        windows.append(controller)
        controller.showWindow(nil)
        NSApp.activate()
    }
}

// Started before anything else runs on the main thread, and kept until the process exits.
let stallWatchdog = StallLogging.start(
    arguments: CommandLine.arguments, logger: Logger(category: "stall"))

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
