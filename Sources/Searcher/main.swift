import AppKit
import Base
import Browser
import Interface
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Listings of network folders, kept in the user's caches folder; nil in a bench launch,
    /// which must not read or write the user's stores.
    private let cache: ListingCache?
    private let service: ListingService
    private let systemActions = WorkspaceSystemActions()
    /// The user's own preferences, made on first use so a bench launch never reads them; the
    /// bench makes its own over a suite of its own.
    private lazy var settings = Settings(defaults: .standard)
    private var windows: [BrowserWindowController] = []
    private let bench: UIBench?

    init(bench: UIBench?) {
        self.bench = bench
        if bench == nil {
            let roots: StoreRoots
            do {
                roots = try StoreRoots.user()
            } catch {
                preconditionFailure("\(error)")
            }
            let logger = Logger(category: "cache")
            let cache = ListingCache(
                store: ListingCacheStore(
                    roots: roots, log: { logger.error("\($0, privacy: .public)") }))
            self.cache = cache
            service = ListingService(cache: cache)
        } else {
            cache = nil
            service = ListingService()
        }
    }

    /// Writes the cache's unwritten saves before the app quits, so listings made in the last two
    /// seconds outlive it. Quits after `quitFlushLimit` whatever the write is doing.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let cache else { return .terminateNow }
        let deadline = ContinuousClock.now.advanced(by: Self.quitFlushLimit)
        Task {
            if !(await cache.flush(by: deadline, clock: .continuous)) {
                let limit = String(describing: Self.quitFlushLimit)
                Logger(category: "cache").fault(
                    "the listing cache didn't finish writing in \(limit, privacy: .public); quitting without it"
                )
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// How long quitting waits for the listing cache to write.
    private static let quitFlushLimit: Duration = .seconds(2)

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let bench {
            // The bench opens its own window and never activates the app.
            bench.start(service: service, systemActions: systemActions)
            return
        }
        installMainMenu()
        let window = openWindow()
        NSApp.activate()
        LaunchWarmup.shared.start(after: window)
    }

    /// A Dock click with no browser window open opens one. With a window open, even a minimized
    /// one, AppKit's own handling brings it back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool)
        -> Bool
    {
        guard bench == nil, windows.isEmpty else { return true }
        openWindow()
        return false
    }

    private func installMainMenu() {
        guard let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
        else {
            preconditionFailure("Info.plist has no CFBundleName for the app menu")
        }
        do {
            try MainMenuBuilder.install(
                in: NSApp, appName: appName, registry: AppCommands.registry(), settings: settings)
        } catch {
            preconditionFailure("the main menu doesn't match the app's commands: \(error)")
        }
    }

    /// Opens a browser window on the home folder. The controller is kept until its window
    /// closes, so a closed window's pane stops watching its folder.
    @discardableResult
    private func openWindow() -> NSWindow {
        let controller = BrowserWindowController(
            location: Location(path: NSHomeDirectory()), service: service,
            systemActions: systemActions, settings: settings)
        guard let window = controller.window else {
            preconditionFailure("a browser window controller has no window")
        }
        windows.append(controller)
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification,
            object: window)
        controller.showWindow(nil)
        return window
    }

    @objc private func windowWillClose(_ notification: Notification) {
        windows.removeAll { $0.window === notification.object as? NSWindow }
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
