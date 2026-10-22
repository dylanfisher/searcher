import AppKit
import Base
import Browser
import os

/// One pane: its list, with a spinner over it while the folder loads, an explanation with a way to
/// grant access when the system refused to list the folder, or a line saying why another folder
/// couldn't be listed, a path bar under it, and a filter field over it after Cmd-F. Keys and
/// double-clicks in the list run the app's commands on this pane, and a folder monitor keeps the
/// rows in step with the folder.
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
    let filterBar = FilterBarView()
    /// The filter bar's height: `FilterBarView.height` while it shows, else 0.
    private var filterBarHeight: NSLayoutConstraint?
    /// The filter whose result VoiceOver last heard, so a patch or reload under the same filter
    /// isn't announced again.
    private var announcedFilter = NameFilter()

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
    /// The Go to folder sheet while it is up.
    private var goToFolderSheet: GoToFolderSheet?

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
        tableView.canRunCommand = { [weak self] id in self?.canRun(id) ?? false }
        tableView.selectTyped = { [weak self] query in self?.selectTyped(query) ?? false }
        pane.onChange = { [weak self] in self?.paneDidChange() }
        pathBar.onSelect = { [weak pane] location, child in
            pane?.navigate(to: location, selecting: child)
        }
        filterBar.isHidden = true
        filterBar.onChange = { [weak pane] text in pane?.setFilter(text) }
        filterBar.onArrow = { [weak tableView] chord in
            guard let tableView, let command = tableView.registry.command(for: chord) else {
                preconditionFailure("no command is bound to \(chord) for the filter field")
            }
            tableView.run(command.id)
        }
        filterBar.onCancel = { [weak self] in self?.closeFilter() }
        filterBar.isFilterChord = { [weak tableView] chord in
            tableView?.registry.command(for: chord)?.id == ViewCommands.filter.id
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
        for view in [filterBar, list, pathBar] {
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
        let filterBarHeight = filterBar.heightAnchor.constraint(equalToConstant: 0)
        self.filterBarHeight = filterBarHeight
        NSLayoutConstraint.activate([
            filterBar.topAnchor.constraint(equalTo: container.topAnchor),
            filterBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            filterBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            filterBarHeight,
            list.topAnchor.constraint(equalTo: filterBar.bottomAnchor),
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
        binding(for: id).run(context)
    }

    private func canRun(_ id: CommandID) -> Bool {
        binding(for: id).isEnabled?(context) ?? true
    }

    private func binding(for id: CommandID) -> CommandBinding {
        guard let binding = Self.bindings[id] else {
            preconditionFailure("no command is bound to \(id)")
        }
        return binding
    }

    private var context: CommandContext {
        CommandContext(
            pane: pane,
            toggleQuickLook: { [listingViewController] in
                listingViewController.quickLook.toggle()
            },
            askForFolder: { [weak self] in self?.askForFolder() },
            showFilter: { [weak self] in self?.showFilter() })
    }

    /// Shows the filter field and focuses it, its text selected. Typing then narrows the rows.
    private func showFilter() {
        _ = view
        filterBar.isHidden = false
        filterBarHeight?.constant = FilterBarView.height
        // Taking focus selects the field's text, so Cmd-F again starts a new query.
        view.window?.makeFirstResponder(filterBar.field)
    }

    /// Esc in the field: clears the filter and hands the focus back to the list.
    private func closeFilter() {
        hideFilter()
        pane.setFilter("")
    }

    /// Hides the filter field, empty, moving the focus to the list first if the field has it:
    /// hiding a first responder would hand focus to the next key view.
    private func hideFilter() {
        if filterBar.field.currentEditor() != nil {
            view.window?.makeFirstResponder(listingViewController.tableView)
        }
        filterBar.field.stringValue = ""
        filterBar.isHidden = true
        filterBarHeight?.constant = 0
    }

    /// Shows the Go to folder sheet over the pane's window, unless it is already up.
    private func askForFolder() {
        guard goToFolderSheet == nil else { return }
        guard let window = view.window else {
            preconditionFailure("Go to folder ran for a pane with no window")
        }
        let sheet = GoToFolderSheet(pane: pane, home: NSHomeDirectory())
        sheet.onClose = { [weak self] in self?.goToFolderSheet = nil }
        goToFolderSheet = sheet
        sheet.present(over: window)
    }

    private func selectTyped(_ query: String) -> Bool {
        SelectionCommands.selectFirstRow(startingWith: query, in: context)
    }

    private func paneDidChange() {
        listingViewController.paneDidChange()
        showState()
        showPath()
        if pane.location != monitoredLocation {
            monitoredLocation = pane.location
            listingViewController.tableView.setAccessibilityLabel(pane.location.name)
            // A query typed in the folder left doesn't carry into this one, and the pane cleared
            // its filter.
            listingViewController.tableView.typeSelect.reset()
            hideFilter()
            // The same query typed again before this folder's listing lands is its first result.
            announcedFilter = NameFilter()
            spinner.setAccessibilityLabel("Loading \(pane.location.name)")
            accessDeniedView.folderName = pane.location.name
            startMonitor()
            onLocationChange?(pane.location)
        }
        announceFilterResult()
        onShow?()
    }

    /// Tells VoiceOver how many rows the filter left once the folder is fully listed under the
    /// pane's latest filter. The pane drops an older query's rows that land after a newer query
    /// started, so keys typed faster than the rows land are announced once.
    private func announceFilterResult() {
        guard case .loaded(let listing) = pane.state, listing.filter == pane.filter,
            listing.filter != announcedFilter
        else { return }
        announcedFilter = listing.filter
        guard !listing.filter.isEmpty else { return }
        filterBar.announceResult(count: listing.count, query: pane.filter.text)
    }

    private func showState() {
        // A slow folder with no rows to show is still loading.
        switch pane.state {
        case .loading, .slow(nil):
            spinner.isHidden = false
            spinner.startAnimation(nil)
        case .partial, .loaded, .cachedRefreshing, .slow(.some), .offline, .denied, .failed:
            spinner.stopAnimation(nil)
            spinner.isHidden = true
        }
        accessDeniedView.isHidden = true
        messageLabel.isHidden = true
        switch pane.state {
        case .loaded(let listing) where listing.count == 0 && !listing.filter.isEmpty:
            // The pane's text as typed: "Port" after "port" folds the same and filters nothing
            // again, but the message follows the field.
            let query = listing.filter == pane.filter ? pane.filter.text : listing.filter.text
            messageLabel.stringValue = FilterBarView.noMatchMessage(query)
            messageLabel.isHidden = false
        // The cached, slow and offline states show their rows; their notes come with the
        // pane's status view.
        case .loading, .partial, .loaded, .cachedRefreshing, .slow, .offline:
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

    /// Starts a monitor for the pane's location on a `BlockingCallThread`, where `FolderMonitor`
    /// must start, and hands it to the pane if the pane is still there when it's ready. Changes it
    /// reports go to the pane on the main actor.
    private func startMonitor() {
        guard monitorsFolders else { return }
        monitorRequest += 1
        let request = monitorRequest
        let location = pane.location
        let logger = logger
        BlockingCallThread.start { [weak self, weak pane] in
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
