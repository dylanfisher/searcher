import AppKit
import Base
import Browser
import Interface
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let service = ListingService()
    private let systemActions = WorkspaceSystemActions()
    private var windows: [BrowserWindowController] = []
    private let bench: UIBench?

    init(bench: UIBench?) {
        self.bench = bench
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let bench {
            // The bench opens its own window and never activates the app.
            bench.start(service: service, systemActions: systemActions)
            return
        }
        let controller = BrowserWindowController(
            location: Location(path: NSHomeDirectory()), service: service,
            systemActions: systemActions)
        windows.append(controller)
        controller.showWindow(nil)
        NSApp.activate()
    }
}

// First, so the launch span starts as early as the app's own code can start it.
let bench = UIBenchOptions(arguments: CommandLine.arguments).map(UIBench.init)

// Started before anything else runs on the main thread, and kept until the process exits.
let stallWatchdog = StallLogging.start(
    arguments: CommandLine.arguments, logger: Logger(category: "stall")
) { stall in bench?.record(stall) }
bench?.watchdog = stallWatchdog

let app = NSApplication.shared
let delegate = AppDelegate(bench: bench)
app.delegate = delegate
// A bench launch has no Dock icon or menu bar, so it stays in the background.
app.setActivationPolicy(bench == nil ? .regular : .accessory)
app.run()
