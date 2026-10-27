import AppKit
import Browser

/// The end of a pane's path bar: a small spinner while the folder's listing is in flight, and a
/// one-line note with the age of the rows shown while the folder is slow or offline, or, once it
/// is listed, how many entries with unreadable names it leaves out.
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
    private let startWait: @MainActor (Duration) -> @Sendable () async throws -> Void
    /// Waits out the spinner delay; nil while the state shown isn't in flight.
    private var spinnerWait: Task<Void, Never>?
    /// Writes the note again when its age turns a minute older; nil while it shows no age.
    private var ageRefresh: Task<Void, Never>?
    /// The listing date `ageRefresh` was timed from.
    private var refreshedListedAt: Date?
    /// The slow or offline state the note shows and the volume it names; nil for no note.
    private var shown: (state: ListingState, volumeName: String)?
    /// How many entries a loaded folder's listing left out for unreadable names; 0 in any other
    /// state.
    private var unreadableNames = 0
    /// Whether the note last announced said offline rather than slow, and the volume it named;
    /// nil since the note went away. A pane that stays slow or offline is announced once.
    private var announced: (isOffline: Bool, volumeName: String)?

    init<C: Clock<Duration>>(
        clock: C = ContinuousClock(), now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.now = now
        startWait = { duration in
            let deadline = clock.now.advanced(by: duration)
            return { try await clock.sleep(until: deadline, tolerance: nil) }
        }
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
    /// holding the folder, and a slow or offline state must have one.
    func show(_ state: ListingState, location: Location, volumeName: String?) {
        spinner.setAccessibilityLabel(PaneStatusText.spinnerLabel(location.name))
        showSpinner(Self.isInFlight(state))
        switch state {
        case .slow, .offline:
            guard let volumeName else {
                preconditionFailure("a pane in \(state) has no volume name")
            }
            shown = (state, volumeName)
        case .loading, .partial, .loaded, .cachedRefreshing, .denied, .failed, .notConnected:
            shown = nil
        }
        // Only a full listing knows how many names it left out.
        unreadableNames =
            if case .loaded(let listing) = state { listing.unreadableNameCount } else { 0 }
        showNote()
        announceNote()
    }

    /// Tells VoiceOver the note when the pane turns slow or offline, or its volume changes, at
    /// high priority so it isn't dropped behind the row being read.
    private func announceNote() {
        guard let shown, !note.isHidden else {
            announced = nil
            return
        }
        let isOffline = if case .offline = shown.state { true } else { false }
        let headline = (isOffline: isOffline, volumeName: shown.volumeName)
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
        case .loaded, .offline, .denied, .failed, .notConnected: false
        }
    }

    private func showSpinner(_ inFlight: Bool) {
        guard inFlight else {
            spinnerWait?.cancel()
            spinnerWait = nil
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            return
        }
        guard spinnerWait == nil else { return }
        let wait = startWait(LoadTimeouts.spinnerDelay)
        spinnerWait = Task { [weak self] in
            do {
                try await wait()
            } catch is CancellationError {
                return
            } catch {
                preconditionFailure("the clock failed a wait with \(error)")
            }
            guard let self, !Task.isCancelled else { return }
            spinner.isHidden = false
            spinner.startAnimation(nil)
        }
    }

    private func showNote() {
        let line =
            shown.flatMap { text.note(for: $0.state, volumeName: $0.volumeName, now: now()) }
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
            do {
                try await wait()
            } catch is CancellationError {
                return
            } catch {
                preconditionFailure("the clock failed a wait with \(error)")
            }
            guard let self, !Task.isCancelled else { return }
            ageRefresh = nil
            showNote()
        }
    }
}
