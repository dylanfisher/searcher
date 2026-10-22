import AppKit
import Browser
import os

/// One pane: its list, with a spinner over it while the folder loads, an explanation with a way to
/// grant access when the system refused to list the folder, or a line saying why another folder
/// couldn't be listed, and a path bar under it. Keys and double-clicks in the list run the app's
/// commands on this pane, and a folder monitor keeps the rows in step with the folder.
///
/// The list stays in place in every state, so the table keeps keyboard focus while a folder
/// loads: hiding a first responder would hand focus to the next key view.
@MainActor
public final class PaneViewController: NSViewController {
    public let pane: Pane
    let listingViewController: ListingViewController
    let spinner = NSProgressIndicator()
    let messageLabel = NSTextField(wrappingLabelWithString: "")
    let accessDeniedView: AccessDeniedView
    let pathBar = PathBarView()

    /// Runs after the pane shows a new location, for the window title.
    public var onLocationChange: (@MainActor (Location) -> Void)?
    /// Runs each time the views have been updated for a change of the pane, in the same run loop
    /// pass, so the UI bench can time the frame that shows it.
    public var onShow: (@MainActor () -> Void)?

    /// The table that takes the pane's keys, for the window's first responder.
    public var keyView: NSView { listingViewController.tableView }

    private static let registry: CommandRegistry = {
        do {
            return try AppCommands.registry()
        } catch {
            preconditionFailure("the app's commands clash: \(error)")
        }
    }()
    private static let bindings = Dictionary(
        uniqueKeysWithValues: AppCommands.bindings.map { ($0.command.id, $0) })

    private let monitorsFolders: Bool
    /// The location the last monitor was started for.
    private var monitoredLocation: Location?
    /// Counts monitor starts, so a monitor that finishes starting after a newer one was asked for
    /// is stopped instead of kept.
    private var monitorRequest = 0
    private let logger = Logger(category: "pane")

    public convenience init(pane: Pane) {
        self.init(
            pane: pane, iconCache: .shared, formatter: .init(), tableView: ListingTableView(),
            monitorsFolders: true)
    }

    /// `monitorsFolders` is false for tests whose folders exist only in a stub lister.
    init(
        pane: Pane, iconCache: TypeIconCache, formatter: EntryCellFormatter,
        tableView: ListingTableView, monitorsFolders: Bool
    ) {
        self.pane = pane
        self.monitorsFolders = monitorsFolders
        accessDeniedView = AccessDeniedView(systemActions: pane.systemActions)
        listingViewController = ListingViewController(
            pane: pane, iconCache: iconCache, formatter: formatter, tableView: tableView)
        super.init(nibName: nil, bundle: nil)
        tableView.registry = Self.registry
        tableView.runCommand = { [weak self] id in self?.run(id) }
        pane.onChange = { [weak self] in self?.paneDidChange() }
        pathBar.onSelect = { [weak pane] location, child in
            pane?.navigate(to: location, selecting: child)
        }
        configureOverlays()
        paneDidChange()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PaneViewController is built in code")
    }

    public override func loadView() {
        let container = NSView()
        let list = listingViewController.view
        // Constraints rather than autoresizing: the container starts at zero size, where a list
        // frame 24 points shorter than it can't be set, and autoresizing would keep the error.
        for view in [list, pathBar] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        addChild(listingViewController)
        for overlay in [spinner, messageLabel, accessDeniedView] {
            overlay.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(overlay)
        }
        // As wide as this in a wide pane; the explanation wraps to fit a narrower one.
        let deniedWidth = accessDeniedView.widthAnchor.constraint(equalToConstant: 420)
        deniedWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: container.topAnchor),
            list.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            list.bottomAnchor.constraint(equalTo: pathBar.topAnchor),
            pathBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            pathBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            pathBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            pathBar.heightAnchor.constraint(equalToConstant: PathBarView.height),
            spinner.centerXAnchor.constraint(equalTo: list.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: list.centerYAnchor),
            messageLabel.centerXAnchor.constraint(equalTo: list.centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: list.centerYAnchor),
            messageLabel.widthAnchor.constraint(
                lessThanOrEqualTo: container.widthAnchor, constant: -40),
            accessDeniedView.centerXAnchor.constraint(equalTo: list.centerXAnchor),
            accessDeniedView.centerYAnchor.constraint(equalTo: list.centerYAnchor),
            accessDeniedView.widthAnchor.constraint(
                lessThanOrEqualTo: container.widthAnchor, constant: -40),
            deniedWidth,
        ])
        view = container
    }

    private func configureOverlays() {
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false
        messageLabel.alignment = .center
        messageLabel.textColor = .secondaryLabelColor
    }

    private func run(_ id: CommandID) {
        guard let binding = Self.bindings[id] else {
            preconditionFailure("no command is bound to \(id)")
        }
        binding.run(
            CommandContext(pane: pane) { [listingViewController] in
                listingViewController.quickLook.toggle()
            })
    }

    private func paneDidChange() {
        listingViewController.paneDidChange()
        showState()
        showPath()
        if pane.location != monitoredLocation {
            monitoredLocation = pane.location
            listingViewController.tableView.setAccessibilityLabel(pane.location.name)
            spinner.setAccessibilityLabel("Loading \(pane.location.name)")
            accessDeniedView.folderName = pane.location.name
            startMonitor()
            onLocationChange?(pane.location)
        }
        onShow?()
    }

    private func showState() {
        if case .loading = pane.state {
            spinner.isHidden = false
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
            spinner.isHidden = true
        }
        accessDeniedView.isHidden = true
        messageLabel.isHidden = true
        switch pane.state {
        case .loading, .partial, .loaded:
            break
        case .denied:
            accessDeniedView.isHidden = false
        case .failed(let error):
            messageLabel.stringValue = error.description
            messageLabel.isHidden = false
        }
    }

    /// Moves the path bar to the pane's location once something of it is on screen: its first
    /// rows, or why it couldn't be listed. While the folder loads the bar keeps showing the
    /// folder the pane left, so it never names a folder whose rows haven't arrived.
    private func showPath() {
        if case .loading = pane.state { return }
        guard let rootVolumeName = pane.rootVolumeName else {
            preconditionFailure("the pane has a listing update but no volume name")
        }
        pathBar.show(pane.location, rootVolumeName: rootVolumeName)
    }

    // MARK: Folder monitor

    /// Starts a monitor for the pane's location off the main thread, where `FolderMonitor` must
    /// start, and hands it to the pane if the pane is still there when it's ready. Changes it
    /// reports go to the pane on the main actor.
    private func startMonitor() {
        guard monitorsFolders else { return }
        monitorRequest += 1
        let request = monitorRequest
        let location = pane.location
        let logger = logger
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak pane] in
            let monitor: FolderMonitor
            do {
                monitor = try FolderMonitor(location: location) { [weak pane] change in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { pane?.apply(change, at: location) }
                    }
                }
            } catch {
                logger.error(
                    "can't watch \(location.path, privacy: .public): \(String(describing: error), privacy: .public)"
                )
                return
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let pane, request == self.monitorRequest,
                        pane.location == location
                    else {
                        monitor.stop()
                        return
                    }
                    pane.monitor = monitor
                }
            }
        }
    }
}
