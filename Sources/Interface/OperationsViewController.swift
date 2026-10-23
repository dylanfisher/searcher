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
/// never brings it up (docs/decisions/0067-operations-panel.md).
@MainActor
final class OperationsViewController: NSViewController {
    /// How long an operation runs before the panel asks to be shown.
    static let attentionDelay: Duration = .seconds(1)
    /// The panel's height while it shows.
    static let height: CGFloat = 132

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

    private let control: Control
    private let formatter = EntryCellFormatter()
    /// Starts a wait of the given length on the clock, taking the deadline at once.
    private let startWait: @MainActor (Duration) -> @Sendable () async throws -> Void
    private let stack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "No operations")
    private var rows: [FileOperationQueue.ID: OperationRowView] = [:]
    /// The unfinished operations' waits for `attentionDelay`.
    private var waits: [FileOperationQueue.ID: Task<Void, Never>] = [:]
    /// Finished operations whose rows stay until cleared.
    private var kept: Set<FileOperationQueue.ID> = []

    init<C: Clock<Duration>>(control: Control, clock: C = ContinuousClock()) {
        self.control = control
        startWait = { duration in
            let deadline = clock.now.advanced(by: duration)
            return { try await clock.sleep(until: deadline, tolerance: nil) }
        }
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("OperationsViewController is built in code")
    }

    func row(for id: FileOperationQueue.ID) -> OperationRowView? {
        rows[id]
    }

    /// Shows the queue's latest snapshots: every unfinished operation, and those finished since
    /// the last ones.
    func show(_ snapshots: [FileOperationQueue.Snapshot]) {
        _ = view
        let listed = Set(snapshots.map(\.id))
        for snapshot in snapshots {
            let id = snapshot.id
            let row = rows[id] ?? addRow(for: id)
            row.show(snapshot)
            let phase = snapshot.state.phase
            if !phase.isFinished {
                if waits[id] == nil { waits[id] = wait(for: id) }
                continue
            }
            waits.removeValue(forKey: id)?.cancel()
            if OperationRowView.isTrouble(phase) {
                if kept.insert(id).inserted { onNeedsAttention?() }
            } else {
                removeRow(id)
            }
        }
        for id in rows.keys where !listed.contains(id) && !kept.contains(id) {
            waits.removeValue(forKey: id)?.cancel()
            removeRow(id)
        }
        emptyLabel.isHidden = !rows.isEmpty
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
        let separator = NSBox()
        separator.boxType = .separator
        let root = NSStackView(views: [separator, scroll])
        root.orientation = .vertical
        root.spacing = 0
        root.setAccessibilityLabel("Operations")
        root.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        view = root
    }

    private func addRow(for id: FileOperationQueue.ID) -> OperationRowView {
        let row = OperationRowView(formatter: formatter)
        let control = control
        row.onPause = { control.pause(id) }
        row.onResume = { control.resume(id) }
        row.onCancel = { control.cancel(id) }
        row.onClear = { [weak self] in self?.clear(id) }
        rows[id] = row
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return row
    }

    private func removeRow(_ id: FileOperationQueue.ID) {
        rows.removeValue(forKey: id)?.removeFromSuperview()
    }

    private func clear(_ id: FileOperationQueue.ID) {
        kept.remove(id)
        removeRow(id)
        emptyLabel.isHidden = !rows.isEmpty
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
            guard let self, !Task.isCancelled, waits.removeValue(forKey: id) != nil else {
                return
            }
            onNeedsAttention?()
        }
    }
}

/// Lays its rows out from the top, as a list reads.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
