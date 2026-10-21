import AppKit
import Browser
import os

/// One pane: its list, with a spinner over it while the folder loads, or a line saying why the
/// folder couldn't be listed. Keys and double-clicks in the list run the app's commands on this
/// pane, and a folder monitor keeps the rows in step with the folder.
///
/// The list stays in place in every state, so the table keeps keyboard focus while a folder
/// loads: hiding a first responder would hand focus to the next key view.
@MainActor
public final class PaneViewController: NSViewController {
    public let pane: Pane
    let listingViewController: ListingViewController
    let spinner = NSProgressIndicator()
    let messageLabel = NSTextField(wrappingLabelWithString: "")

    /// Runs after the pane shows a new location, for the window title.
    public var onLocationChange: (@MainActor (Location) -> Void)?

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
        listingViewController = ListingViewController(
            pane: pane, iconCache: iconCache, formatter: formatter, tableView: tableView)
        super.init(nibName: nil, bundle: nil)
        tableView.registry = Self.registry
        tableView.runCommand = { [weak self] id in self?.run(id) }
        pane.onChange = { [weak self] in self?.paneDidChange() }
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
        list.frame = container.bounds
        list.autoresizingMask = [.width, .height]
        container.addSubview(list)
        addChild(listingViewController)
        for overlay in [spinner, messageLabel] {
            overlay.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(overlay)
        }
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            messageLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            messageLabel.widthAnchor.constraint(
                lessThanOrEqualTo: container.widthAnchor, constant: -40),
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
        binding.run(CommandContext(pane: pane))
    }

    private func paneDidChange() {
        listingViewController.paneDidChange()
        showState()
        if pane.location != monitoredLocation {
            monitoredLocation = pane.location
            listingViewController.tableView.setAccessibilityLabel(pane.location.name)
            spinner.setAccessibilityLabel("Loading \(pane.location.name)")
            startMonitor()
            onLocationChange?(pane.location)
        }
    }

    private func showState() {
        switch pane.state {
        case .loading:
            spinner.isHidden = false
            spinner.startAnimation(nil)
            messageLabel.isHidden = true
        case .partial, .loaded:
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            messageLabel.isHidden = true
        case .denied(let error), .failed(let error):
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            messageLabel.stringValue = error.description
            messageLabel.isHidden = false
        }
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
