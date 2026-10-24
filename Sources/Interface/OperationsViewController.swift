import AppKit
import Browser

/// The operations panel at the bottom of a browser window: one `OperationRowView` per running
/// or queued file operation, in the order queued. It shows only the queue's snapshots and sends
/// pause, resume and cancel through `Control`, so it never reads the file system or waits on the
/// queue. A finished operation leaves the panel, unless it failed, was refused, or left part of
/// an item behind: that row stays, showing why, until the user clears it.
///
/// It asks to be shown (`onNeedsAttention`) when an operation is still unfinished
/// `attentionDelay` after the panel first saw it, or finishes in trouble, so a short operation
/// never brings it up. A copy whose rate so far leaves `longEstimate` or more to go asks at once,
/// a tick after it is first sampled. Each operation asks at most once, so a panel the user closed
/// stays closed until another operation asks (docs/decisions/0067-operations-panel.md).
@MainActor
final class OperationsViewController: NSViewController {
    /// How long an operation runs before the panel asks to be shown.
    static let attentionDelay: Duration = .seconds(1)
    /// How much copying, estimated from the rate between two ticks, has the panel ask to be shown
    /// before `attentionDelay`.
    static let longEstimate: Duration = .seconds(2)
    /// The tallest the panel grows, about three rows; past it the rows scroll.
    static let maxHeight: CGFloat = 200
    /// The height of the line saying there are no operations.
    private static let emptyHeight: CGFloat = 32

    /// What the row buttons send for an operation.
    struct Control {
        let pause: @MainActor (FileOperationQueue.ID) -> Void
        let resume: @MainActor (FileOperationQueue.ID) -> Void
        let cancel: @MainActor (FileOperationQueue.ID) -> Void

        /// Sends each call to `queue`.
        static func sending(to queue: FileOperationQueue) -> Control {
            Control(
                pause: { id in Task { await queue.pause(id) } },
                resume: { id in Task { await queue.resume(id) } },
                cancel: { id in Task { await queue.cancel(id) } })
        }

        /// For a window with no queue, which has no operations to act on.
        static let none = Control(
            pause: { preconditionFailure("\($0) has no queue to pause it") },
            resume: { preconditionFailure("\($0) has no queue to resume it") },
            cancel: { preconditionFailure("\($0) has no queue to cancel it") })
    }

    /// Runs when an operation has been unfinished for `attentionDelay`, or finished in trouble.
    var onNeedsAttention: (@MainActor () -> Void)?
    /// Runs when the user clears a finished row, so every window can clear it with `clear`.
    /// Without it the row clears here only.
    var onClear: (@MainActor (FileOperationQueue.ID) -> Void)?

    private let control: Control
    private let formatter = EntryCellFormatter()
    /// Starts a wait of the given length on the clock, taking the deadline at once.
    private let startWait: @MainActor (Duration) -> @Sendable () async throws -> Void
    /// The time on the clock since the panel was made.
    private let elapsed: @MainActor () -> Duration
    private let stack = NSStackView()
    /// Holds `emptyLabel` as the panel's only row while there are no others.
    private let emptyRow = NSView()
    /// Runs when the last row leaves the panel.
    var onEmptied: (@MainActor () -> Void)?
    let emptyLabel = NSTextField(labelWithString: "No operations")
    private var rows: [FileOperationQueue.ID: OperationRowView] = [:]
    /// The unfinished operations' waits for `attentionDelay`.
    private var waits: [FileOperationQueue.ID: Task<Void, Never>] = [:]
    /// Finished operations whose rows stay until cleared.
    private var kept: Set<FileOperationQueue.ID> = []
    /// Each running copy's first tick with a total, to tell its rate from the next: when the
    /// tick came, and the bytes copied by then.
    private var samples: [FileOperationQueue.ID: (at: Duration, bytes: Int64)] = [:]
    /// Unfinished operations the panel has asked to be shown for, by the wait or the estimate.
    private var asked: Set<FileOperationQueue.ID> = []

    init<C: Clock<Duration>>(control: Control, clock: C = ContinuousClock()) {
        self.control = control
        startWait = { duration in
            let deadline = clock.now.advanced(by: duration)
            return { try await clock.sleep(until: deadline, tolerance: nil) }
        }
        let start = clock.now
        elapsed = { start.duration(to: clock.now) }
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("OperationsViewController is built in code")
    }

    func row(for id: FileOperationQueue.ID) -> OperationRowView? {
        rows[id]
    }

    /// Whether the panel has no rows.
    var isEmpty: Bool { rows.isEmpty }

    /// Shows the queue's latest snapshots: every unfinished operation, and those finished since
    /// the last ones.
    func show(_ snapshots: [FileOperationQueue.Snapshot]) {
        _ = view
        let wasEmpty = rows.isEmpty
        let listed = Set(snapshots.map(\.id))
        for snapshot in snapshots {
            let id = snapshot.id
            let row = rows[id] ?? addRow(for: id)
            row.show(snapshot)
            let phase = snapshot.state.phase
            if !phase.isFinished {
                guard !asked.contains(id) else { continue }
                if waits[id] == nil { waits[id] = wait(for: id) }
                estimate(snapshot)
                continue
            }
            forget(id)
            if OperationRowView.isTrouble(phase) {
                if kept.insert(id).inserted { onNeedsAttention?() }
            } else {
                removeRow(id)
            }
        }
        for id in rows.keys where !listed.contains(id) && !kept.contains(id) {
            forget(id)
            removeRow(id)
        }
        showEmpty(wasEmpty: wasEmpty)
    }

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = document
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyRow.addSubview(emptyLabel)
        stack.addArrangedSubview(emptyRow)
        let separator = NSBox()
        separator.boxType = .separator
        let root = NSStackView(views: [separator, scroll])
        root.orientation = .vertical
        root.spacing = 0
        root.setAccessibilityLabel("Operations")
        // As tall as the rows, up to `maxHeight`; the panes above give up the room.
        let fitsRows = scroll.heightAnchor.constraint(equalTo: document.heightAnchor)
        fitsRows.priority = .defaultHigh
        NSLayoutConstraint.activate([
            fitsRows,
            root.heightAnchor.constraint(lessThanOrEqualToConstant: Self.maxHeight),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            emptyRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            emptyRow.heightAnchor.constraint(equalToConstant: Self.emptyHeight),
            emptyLabel.centerXAnchor.constraint(equalTo: emptyRow.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: emptyRow.centerYAnchor),
        ])
        view = root
    }

    private func addRow(for id: FileOperationQueue.ID) -> OperationRowView {
        let row = OperationRowView(formatter: formatter)
        let control = control
        row.onPause = { control.pause(id) }
        row.onResume = { control.resume(id) }
        row.onCancel = { control.cancel(id) }
        row.onClear = { [weak self] in
            guard let self else { return }
            if let onClear { onClear(id) } else { clear(id) }
        }
        rows[id] = row
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return row
    }

    private func removeRow(_ id: FileOperationQueue.ID) {
        rows.removeValue(forKey: id)?.removeFromSuperview()
    }

    /// Drops the finished row of `id`, if there is one.
    func clear(_ id: FileOperationQueue.ID) {
        let wasEmpty = rows.isEmpty
        kept.remove(id)
        removeRow(id)
        showEmpty(wasEmpty: wasEmpty)
    }

    /// Shows the empty line while there are no rows, and says so when the last one left.
    private func showEmpty(wasEmpty: Bool) {
        emptyRow.isHidden = !rows.isEmpty
        if rows.isEmpty, !wasEmpty { onEmptied?() }
    }

    /// Drops the wait, sample and ask of a finished or vanished operation.
    private func forget(_ id: FileOperationQueue.ID) {
        waits.removeValue(forKey: id)?.cancel()
        samples.removeValue(forKey: id)
        asked.remove(id)
    }

    /// Asks to be shown for `id`, once: its wait and sampling stop.
    private func ask(for id: FileOperationQueue.ID) {
        asked.insert(id)
        waits.removeValue(forKey: id)?.cancel()
        samples.removeValue(forKey: id)
        onNeedsAttention?()
    }

    /// Asks to be shown if the copy in `snapshot` has `longEstimate` or more to go at the rate
    /// since its sample. Only a running copy with a total is sampled; a pause, or a tick without
    /// bytes moving, starts the sampling over.
    private func estimate(_ snapshot: FileOperationQueue.Snapshot) {
        let id = snapshot.id
        let progress = snapshot.state.progress
        guard snapshot.state.phase == .running, let total = progress.total else {
            samples.removeValue(forKey: id)
            return
        }
        let now = elapsed()
        let copied = progress.copied.bytes
        guard let sample = samples[id], copied > sample.bytes, now > sample.at else {
            samples[id] = (now, copied)
            return
        }
        // Bytes left for each byte copied since the sample.
        let ratio = Double(total.bytes - copied) / Double(copied - sample.bytes)
        if (now - sample.at) * ratio >= Self.longEstimate { ask(for: id) }
    }

    /// Asks to be shown if `id` is still unfinished once `attentionDelay` has passed.
    private func wait(for id: FileOperationQueue.ID) -> Task<Void, Never> {
        let wait = startWait(Self.attentionDelay)
        return Task { [weak self] in
            do {
                try await wait()
            } catch is CancellationError {
                return
            } catch {
                preconditionFailure("the clock failed a wait with \(error)")
            }
            guard let self, !Task.isCancelled, waits[id] != nil else { return }
            ask(for: id)
        }
    }
}

/// Lays its rows out from the top, as a list reads.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
