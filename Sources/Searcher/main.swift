import AppKit
import Base
import Browser
import Interface
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, SettingsShowing {
    /// Listings of network folders, kept in the user's caches folder; nil in a bench launch,
    /// which must not read or write the user's stores and brings its own service.
    private let cache: ListingCache?
    private let service: ListingService
    /// Walks the windows' folders for their sizes; nil in a bench launch, which shows none.
    private let folderSizes: FolderSizeService?
    private let systemActions = WorkspaceSystemActions()
    /// The user's own settings, made on first use so a bench launch never reads them; the bench
    /// makes its own over a suite of its own, with no config file. Launch connects the config
    /// file.
    private lazy var settings = Settings(
        defaults: .standard, log: { Logger(category: "settings").error("\($0)") })
    /// The browser windows, made on first use so a bench launch, which opens its own window,
    /// never makes them. They share the service's mount table, the app's one.
    private lazy var windows: WorkspaceWindows = {
        guard let mounts = service.mounts else {
            preconditionFailure(
                "the windows are made in a bench launch, whose service has no mount table")
        }
        return WorkspaceWindows(
            service: service, mountTable: mounts, systemActions: systemActions,
            settings: settings, folderSizes: folderSizes,
            clipboard: PasteboardFileClipboard(pasteboard: .general), store: workspaceStore,
            cache: cache)
    }()
    /// The one Settings window, made the first time App ▸ Settings… asks for it.
    private lazy var settingsWindow = SettingsWindowController(
        settings: settings, systemActions: systemActions)
    /// Runs the menu items that reach the delegate, made on first use so a bench launch, whose
    /// items are off, never makes it.
    private lazy var appMenu = AppMenuResponder(
        settings: settings, systemActions: systemActions,
        openWindow: { [unowned self] in openHomeWindow() })
    private let bench: UIBench?
    /// The windows' workspaces and the session, in the user's application support folder; nil
    /// in a bench launch.
    private let workspaceStore: WorkspaceStore?
    /// What `workspaceStore` reports it couldn't read or write, for the windows to show.
    private let storeProblems: AsyncStream<StoreProblem>?
    /// The store's read of the last session, then the listing cache's read of the volume files
    /// its panes' folders are kept in, started as the app starts so they run off the main actor
    /// while AppKit finishes launching; nil in a bench launch.
    private let restoring: Task<WorkspaceStore.Contents, Never>?
    /// The store's read of the palette's folder history, started beside the session's; nil in
    /// a bench launch.
    private let folderHistory: Task<FolderHistory, Never>?

    init(bench: UIBench?) {
        self.bench = bench
        if let bench {
            cache = nil
            service = bench.service
            folderSizes = nil
            workspaceStore = nil
            storeProblems = nil
            restoring = nil
            folderHistory = nil
        } else {
            let roots: StoreRoots
            do {
                roots = try StoreRoots.user()
            } catch {
                preconditionFailure("\(error)")
            }
            let logger = Logger(category: "cache")
            // One store, so a share's sizes are kept in its volume file beside its listings.
            let store = ListingCacheStore(
                roots: roots, log: { logger.error("\($0)") })
            let cache = ListingCache(store: store)
            self.cache = cache
            // The app's one mount table: the service lists servers from it, and the windows'
            // drops read it (docs/decisions/0114-server-location.md). A server's listing adds
            // the shares it offers that aren't mounted, and opening one mounts it
            // (docs/decisions/0115-server-shares.md).
            let mounts = MountTable()
            service = ListingService(
                cache: cache, thumbnails: ThumbnailService(), recentListings: RecentListings(),
                mounts: mounts, shares: ServerShares(),
                shareMounts: ShareMounts(mounter: NetFSShareMounter(), table: mounts))
            let sizeLogger = Logger(category: "sizes")
            let dropLogger = Logger(category: "folderSizes")
            folderSizes = FolderSizeService(
                cache: FolderSizeCache(
                    store: store, debugLog: { dropLogger.debug("\($0)") }),
                log: { sizeLogger.error("\($0)") })
            let (problems, problemFeed) = AsyncStream.makeStream(of: StoreProblem.self)
            storeProblems = problems
            let workspaceStore = WorkspaceStore(roots: roots, report: { problemFeed.yield($0) })
            self.workspaceStore = workspaceStore
            restoring = Task {
                let contents = await workspaceStore.load()
                // Before any pane loads, so a restored pane on a share finds its rows in memory,
                // and one on a share that isn't mounted finds them at all. Reads the cache's
                // files and the mount table, never a share.
                await cache.restore(contents)
                return contents
            }
            folderHistory = Task { await workspaceStore.loadFolderHistory() }
        }
    }

    /// Asks first while file operations are unfinished, and stays open on Cancel. Then writes
    /// the windows' workspaces and the session, so the next launch opens them as they are now,
    /// cancels the running file operations, so none leaves a partial item or a staging folder,
    /// and writes the cache's unwritten saves before the app quits, so listings made in the last
    /// two seconds outlive it. Quits after `quitLimit` whatever any of them is doing.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A bench launch has no cache and never makes the windows.
        guard let cache else { return .terminateNow }
        guard windows.shouldQuit(asking: { $0.runModal() == .alertFirstButtonReturn }) else {
            return .terminateCancel
        }
        let deadline = ContinuousClock.now.advanced(by: Self.quitLimit)
        let windows = windows
        Task {
            let limit = String(describing: Self.quitLimit)
            // First: it takes a few small writes, and losing it loses the windows. Before the
            // restore runs it writes nothing, so the session on disk stays for the next launch.
            if windows.awaitsRestore {
                Logger(category: "workspaces").notice(
                    "quitting before the last session was restored; it stays as saved")
            }
            // A setting changed in the last second is still waiting on its write's delay. It
            // runs beside the other steps, on the store's actor, so a config file on a share
            // that hangs delays none of them, and is given the same deadline.
            let settings = settings
            let configFlushed = Task {
                await settings.flushConfig(by: deadline, clock: .continuous)
            }
            if !(await windows.saveBeforeQuit(by: deadline)) {
                Logger(category: "workspaces").fault(
                    "the windows weren't saved in \(limit, privacy: .public); quitting anyway")
            }
            if !(await windows.cancelOperationsBeforeQuit(by: deadline)) {
                Logger(category: "operations").fault(
                    "file operations didn't stop in \(limit, privacy: .public); quitting anyway")
            }
            if !(await cache.flush(by: deadline, clock: .continuous)) {
                Logger(category: "cache").fault(
                    "the listing cache didn't finish writing in \(limit, privacy: .public); quitting without it"
                )
            }
            if !(await configFlushed.value) {
                Logger(category: "config").fault(
                    "the config file wasn't written in \(limit, privacy: .public); quitting without it"
                )
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// How long quitting waits for the windows to be saved, file operations to stop, and the
    /// listing cache and the config file to write.
    private static let quitLimit: Duration = .seconds(2)

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let bench {
            // The bench opens its own window and never activates the app.
            bench.start(systemActions: systemActions)
            return
        }
        // Before any window opens, so none shows in the system's appearance first.
        settings.applyAppearance(to: NSApp)
        installMainMenu()
        VolumeNotifications.start()
        guard let restoring, let folderHistory, let storeProblems else {
            preconditionFailure("a launch that isn't a bench has no workspace store")
        }
        windows.follow(storeProblems: storeProblems)
        // Until the restore runs, a quit or a window opened meanwhile saves nothing over the
        // session being read.
        windows.holdSavesUntilRestore()
        let configLogger = Logger(category: "config")
        let settings = settings
        Task {
            // The config file's settings first, so the windows open with them. The store reads
            // on its own actor, as the workspace store does, so the main thread waits on no file.
            await settings.connectConfig(
                defaultFile: Settings.userConfigFile(home: settings.home)
            ) { file, isDefault in
                ConfigStore(
                    file: file, createsFolder: isDefault, reserved: MainMenuBuilder.reservedChords,
                    fixed: MainMenuBuilder.fixedChords, log: { configLogger.error("\($0)") })
            }
            // The store reads on its own actor, so the main thread waits on no file.
            let contents = await restoring.value
            let window = await windows.restore(contents)?.window ?? openHomeWindow()
            NSApp.activate()
            LaunchWarmup.shared.start(after: window)
        }
        // The windows don't wait for it: visits counted before it arrives are added to it.
        Task { windows.folderVisits.load(await folderHistory.value) }
    }

    /// Promised files still on their way when the app quits leave their hidden drop folders;
    /// those are removed now. A server's share list still running is ended, so its process
    /// doesn't outlive the app (docs/decisions/0115-server-shares.md).
    func applicationWillTerminate(_ notification: Notification) {
        guard bench == nil else { return }
        windows.removeDropFoldersBeforeQuit()
        service.shares?.stop()
    }

    /// Another app may have written the clipboard while the user was in it, which ends a cut,
    /// so the cut rows stop looking dimmed; the sidebar's favorites may have moved, been
    /// renamed or come back, so they are looked for again; and a server may offer a share it
    /// didn't, so panes at a server list it again, past the share list's cached time.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard bench == nil else { return }
        windows.clipboard.clipboardMayHaveChanged()
        windows.favorites.refresh()
        service.shares?.relistServers()
    }

    /// A Dock click with no browser window open opens one. With a window open, even a minimized
    /// one, AppKit's own handling brings it back. While the last session is being read, the
    /// click waits for the restore, which opens the windows.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool)
        -> Bool
    {
        guard bench == nil else { return true }
        if windows.awaitsRestore { return false }
        guard windows.opensWindowOnReopen else { return true }
        openHomeWindow()
        return false
    }

    /// A menu item that reaches the app's delegate, as when no browser window has the keys, goes
    /// to `appMenu`: New Window opens a window on the home folder, and Open Config File opens
    /// the config file.
    @objc func runMenuCommand(_ sender: NSMenuItem) {
        appMenu.runMenuCommand(sender)
    }

    /// App ▸ Settings… brings the one Settings window to the front, making it the first time.
    func showSettings(_ sender: Any?) {
        settingsWindow.show()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(runMenuCommand(_:)) else { return true }
        return bench == nil && appMenu.validateMenuItem(item)
    }

    private func installMainMenu() {
        guard let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
        else {
            preconditionFailure("Info.plist has no CFBundleName for the app menu")
        }
        do {
            try MainMenuBuilder.install(in: NSApp, appName: appName, settings: settings)
        } catch {
            preconditionFailure("the main menu doesn't match the app's commands: \(error)")
        }
    }

    /// Opens a browser window on the home folder.
    @discardableResult
    private func openHomeWindow() -> NSWindow {
        windows.open(at: Location(path: settings.home)).requiredWindow
    }
}

// First, so the launch span starts as early as the app's own code can start it.
let bench = UIBenchOptions(
    arguments: CommandLine.arguments, environment: ProcessInfo.processInfo.environment
).map(UIBench.init)

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
