import AppKit
import Base
import Browser

/// The end of a pane's path bar: a small spinner while the folder's listing is in flight, and a
/// one-line note: the age of the rows shown while the folder is slow or offline; else why a
/// server's rows may not be all its shares; else, once a folder is listed, how many entries with
/// unreadable names it leaves out.
///
/// The spinner waits `LoadTimeouts.spinnerDelay` on the injected clock, so a folder that lists
/// quickly never flashes one. The note's age is reckoned from the injected date and written again
/// as each minute passes from when the rows were listed. It shows only what it's given, so it
/// makes no file-system call.
@MainActor
final class PaneStatusView: NSView {
    /// Posts an accessibility notification. Tests replace it to record what would be posted.
    var postAccessibility:
        @MainActor (
            Any, NSAccessibility.Notification, [NSAccessibility.NotificationUserInfoKey: Any]?
        )
            -> Void = { element, notification, userInfo in
                NSAccessibility.post(
                    element: element, notification: notification, userInfo: userInfo)
            }
    let spinner = NSProgressIndicator()
    let note = NSTextField(labelWithString: "")

    private let text = PaneStatusText()
    private let now: @MainActor () -> Date
    /// Starts a wait of the given length on the clock, taking the deadline at once, and returns
    /// the wait.
    private let startWait: DeadlineWait.Start
    /// Waits out the spinner delay; nil while the state shown isn't in flight.
    private var spinnerWait: Task<Void, Never>?
    /// Writes the note again when its age turns a minute older; nil while it shows no age.
    private var ageRefresh: Task<Void, Never>?
    /// The listing date `ageRefresh` was timed from.
    private var refreshedListedAt: Date?
    /// The slow, offline or server state the note shows and the volume or server it names; nil
    /// for no note.
    private var shown: (state: ListingState, volumeName: String)?
    /// How many entries a loaded folder's listing left out for unreadable names; 0 in any other
    /// state, and at a server, whose rows are its shares.
    private var unreadableNames = 0
    /// The share being mounted, which the note names over anything else; nil for none.
    private var connecting: String?
    /// What the note last announced said, and the volume or server it named; nil since the note
    /// went away. A pane that stays slow or offline, or keeps its notice, is announced once.
    private var announced: (headline: Headline, volumeName: String)?

    /// What a note says, but its age.
    private enum Headline: Equatable {
        case slow
        case offline
        case notice(ServerNotice)
    }

    init<C: Clock<Duration>>(
        clock: C = ContinuousClock(), now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.now = now
        startWait = DeadlineWait.make(on: clock)
        super.init(frame: .zero)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byTruncatingTail
        note.isHidden = true
        // The path bar keeps its room before the note does; the note truncates.
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [note, spinner])
        row.orientation = .horizontal
        row.spacing = 6
        row.detachesHiddenViews = true
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PaneStatusView is built in code")
    }

    /// Shows the spinner and note for `state` of the folder at `location`. A state that stays in
    /// flight from one call to the next keeps its spinner wait. `volumeName` names the volume
    /// holding the folder, and a slow or offline state must have one. A server's notice names
    /// the server at `location`.
    /// `connecting` names a share of the server at `location` whose mount the pane has waited
    /// `LoadTimeouts.spinnerDelay` for: the spinner shows at once and the note says so, over any
    /// other.
    func show(
        _ state: ListingState, location: Location, volumeName: String?,
        connecting: String? = nil
    ) {
        self.connecting = connecting
        if connecting != nil {
            spinner.setAccessibilityLabel(ListingViewController.connectingLabel)
            showSpinner(true, waits: false)
        } else {
            spinner.setAccessibilityLabel(PaneStatusText.spinnerLabel(location.name))
            showSpinner(Self.isInFlight(state))
        }
        switch state {
        case .slow, .offline:
            guard let volumeName else {
                preconditionFailure("a pane in \(state) has no volume name")
            }
            shown = (state, volumeName)
        case .serverListed:
            shown = (state, location.name)
        case .loading, .partial, .loaded, .cachedRefreshing, .denied, .failed, .notConnected:
            shown = nil
        }
        // Only a full listing of a folder knows how many names it left out; a server's rows are
        // its shares, never read from a folder.
        unreadableNames =
            if case .loaded(let listing) = state, location.isFolder {
                listing.unreadableNameCount
            } else {
                0
            }
        showNote()
        announceNote()
    }

    /// Tells VoiceOver the note when the pane turns slow or offline, or its volume changes, at
    /// high priority so it isn't dropped behind the row being read.
    private func announceNote() {
        guard connecting == nil, let shown, !note.isHidden else {
            announced = nil
            return
        }
        let said: Headline =
            switch shown.state {
            case .offline: .offline
            case .serverListed(_, let notice): .notice(notice)
            case .loading, .partial, .loaded, .cachedRefreshing, .slow, .denied, .failed,
                .notConnected:
                .slow
            }
        let headline = (headline: said, volumeName: shown.volumeName)
        guard announced.map({ $0 != headline }) ?? true else { return }
        announced = headline
        postAccessibility(
            note, .announcementRequested,
            [
                .announcement: note.stringValue,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
    }

    /// Whether the folder's listing is still on its way: nothing yet, a first batch, cached rows,
    /// or a slow read. An offline pane's load keeps going, but the note says it gave up. Each
    /// column of column view shows its own spinner by it too.
    static func isInFlight(_ state: ListingState) -> Bool {
        switch state {
        case .loading, .partial, .cachedRefreshing, .slow: true
        case .loaded, .offline, .denied, .failed, .notConnected, .serverListed: false
        }
    }

    /// Shows the spinner while `inFlight`, once `LoadTimeouts.spinnerDelay` has passed unless
    /// it doesn't `wait`.
    private func showSpinner(_ inFlight: Bool, waits: Bool = true) {
        guard inFlight else {
            spinnerWait?.cancel()
            spinnerWait = nil
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            return
        }
        guard waits else {
            spinnerWait?.cancel()
            spinnerWait = nil
            spinner.isHidden = false
            spinner.startAnimation(nil)
            return
        }
        guard spinnerWait == nil else { return }
        let wait = startWait(LoadTimeouts.spinnerDelay)
        spinnerWait = Task { [weak self] in
            guard await DeadlineWait.reached(wait) else { return }
            guard let self, !Task.isCancelled else { return }
            spinner.isHidden = false
            spinner.startAnimation(nil)
        }
    }

    private func showNote() {
        // In order: a share being mounted; slow or offline, then a server's notice, both from
        // `shown`, which holds one state; then a listed folder's unreadable names, which a
        // server never has.
        let line =
            connecting.map(PaneStatusText.connectingNote)
            ?? shown.flatMap { text.note(for: $0.state, volumeName: $0.volumeName, now: now()) }
            ?? PaneStatusText.unreadableNamesNote(unreadableNames)
        // Set only on a change: most calls come from pane changes that leave the note as it is.
        if note.stringValue != line ?? "" { note.stringValue = line ?? "" }
        note.isHidden = line == nil
        guard let listedAt = shown?.state.listedAt else {
            ageRefresh?.cancel()
            ageRefresh = nil
            refreshedListedAt = nil
            return
        }
        guard ageRefresh == nil || refreshedListedAt != listedAt else { return }
        ageRefresh?.cancel()
        refreshedListedAt = listedAt
        refreshAge(after: PaneStatusText.nextAgeChange(listedAt: listedAt, now: now()))
    }

    /// Writes the note again once `delay` has passed on the clock, when its age turns a minute
    /// older, and from there each time it does.
    private func refreshAge(after delay: Duration) {
        let wait = startWait(delay)
        ageRefresh = Task { [weak self] in
            guard await DeadlineWait.reached(wait) else { return }
            guard let self, !Task.isCancelled else { return }
            ageRefresh = nil
            showNote()
        }
    }
}
