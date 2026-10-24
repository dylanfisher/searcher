import AppKit
import Base
import Browser

/// One operation in the operations panel: what it does, a progress bar, a line saying how far it
/// got or why it stopped, and buttons to pause or resume it and to cancel it. Once a failed or
/// refused operation has finished, the cancel button clears its row instead. It shows only the
/// snapshots it is given.
@MainActor
final class OperationRowView: NSView {
    let titleLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")
    let bar = NSProgressIndicator()
    /// Pause while the operation runs, Resume while it is paused.
    let pauseButton = NSButton()
    /// Cancel while the operation is unfinished, Clear once it has finished.
    let cancelButton = NSButton()

    var onPause: @MainActor () -> Void = {}
    var onResume: @MainActor () -> Void = {}
    var onCancel: @MainActor () -> Void = {}
    var onClear: @MainActor () -> Void = {}

    private let formatter: EntryCellFormatter
    /// The phase shown; nil before the first snapshot.
    private var phase: OperationState.Phase?

    init(formatter: EntryCellFormatter) {
        self.formatter = formatter
        super.init(frame: .zero)
        buildContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("OperationRowView is built in code")
    }

    func show(_ snapshot: FileOperationQueue.Snapshot) {
        let state = snapshot.state
        let old = phase
        phase = state.phase
        titleLabel.stringValue = Self.title(of: snapshot.operation)
        detailLabel.stringValue = detail(of: snapshot)
        showBar(state)
        guard state.phase != old else { return }
        // A copy sends a snapshot every 100 ms; the buttons change only with the phase.
        detailLabel.textColor = Self.isTrouble(state.phase) ? .systemRed : .secondaryLabelColor
        let isPaused = state.phase == .paused
        if old.map({ $0 == .paused }) != isPaused {
            pauseButton.image = symbol(isPaused ? "play.fill" : "pause.fill")
            pauseButton.setAccessibilityLabel(isPaused ? "Resume" : "Pause")
        }
        let isFinished = state.phase.isFinished
        pauseButton.isHidden = isFinished
        if old?.isFinished != isFinished {
            cancelButton.image = symbol(isFinished ? "xmark" : "xmark.circle.fill")
            cancelButton.setAccessibilityLabel(isFinished ? "Clear" : "Cancel")
        }
    }

    /// A finished operation the user should read about: it failed, was refused, or was
    /// cancelled leaving part of an item behind.
    static func isTrouble(_ phase: OperationState.Phase) -> Bool {
        switch phase {
        case .failed, .refused, .cancelled(leftBehind: .some): true
        case .queued, .preparing, .running, .paused, .waitingForAnswer, .done,
            .cancelled(leftBehind: nil):
            false
        }
    }

    // MARK: Text

    static func title(of operation: FileOperation) -> String {
        switch operation {
        case .copy(let paths, let folder):
            "Copying \(items(paths)) to \(quoted(folder))"
        case .move(let paths, let folder):
            "Moving \(items(paths)) to \(quoted(folder))"
        case .trash(let paths):
            "Moving \(items(paths)) to the Trash"
        case .rename(let path, let name):
            "Renaming \(quoted(path)) to “\(name)”"
        case .newFolder(let folder):
            "Making a folder in \(quoted(folder))"
        case .duplicate(let paths):
            "Duplicating \(items(paths))"
        case .deleteImmediately(let paths):
            "Deleting \(items(paths))"
        case .receive(let name?, _, let folder):
            "Drop of “\(name)” into \(quoted(folder))"
        case .receive(nil, let app?, let folder):
            "Drop from \(app) into \(quoted(folder))"
        case .receive(nil, nil, let folder):
            "Drop into \(quoted(folder))"
        case .undo(_, let title, _):
            title
        }
    }

    /// "“name”" for one item, "N items" for more.
    static func items(_ paths: [String]) -> String {
        paths.count == 1 ? quoted(paths[0]) : "\(paths.count) items"
    }

    /// The last part of `path`, in quotes.
    static func quoted(_ path: String) -> String {
        "“\(Location(path: path).name)”"
    }

    private func detail(of snapshot: FileOperationQueue.Snapshot) -> String {
        let state = snapshot.state
        return switch state.phase {
        case .queued: "Waiting for other copies to this disk"
        case .preparing: "Preparing…"
        case .waitingForAnswer: "Waiting for an answer"
        case .running: progress(state.progress)
        case .paused: "Paused, \(progress(state.progress))"
        case .done: "Done"
        case .failed where FileOperation.dropsUndoEntry(snapshot.operation, after: state):
            // An undo that can't clear by trying again is dropped from the Edit menu.
            Self.failure(state.errors) + " This undo is dropped."
        case .failed: Self.failure(state.errors)
        case .refused(.inUse(let path)):
            "Not started: another operation is using “\(path)”."
        case .refused(.intoItself(let source)):
            "Not started: “\(source)” can’t go into itself."
        case .cancelled(leftBehind: nil): "Cancelled"
        case .cancelled(leftBehind: let error?):
            "Cancelled, but part of it is left behind. \(Self.describe(error))"
        }
    }

    private func progress(_ progress: OperationState.Progress) -> String {
        guard let total = progress.total else {
            return "\(progress.itemsDone) of \(progress.itemCount) items"
        }
        let totalBytes =
            (total.isPartial ? EntryCellFormatter.partialPrefix : "") + formatter.bytes(total.bytes)
        let bytes = "\(formatter.bytes(progress.copied.bytes)) of \(totalBytes)"
        return "\(bytes), \(progress.copied.files) of \(total.files) files"
    }

    /// The first error, and how many more there are.
    private static func failure(_ errors: [FileOperationError]) -> String {
        guard let first = errors.first else {
            preconditionFailure("an operation failed with no error")
        }
        let more = errors.count - 1
        return describe(first) + (more > 0 ? " \(more) more failed." : "")
    }

    /// What went wrong, naming the full path.
    static func describe(_ error: FileOperationError) -> String {
        let path = "“\(error.path)”"
        return switch error.reason {
        case .noSpace: "There isn’t enough space for \(path)."
        case .permissionDenied: "There’s no permission to change \(path)."
        case .sourceGone: "\(path) is gone."
        case .unreachable: "\(path) stopped answering."
        case .exists: "\(path) already exists."
        case .crossVolume: "\(path) is on another volume."
        case .noTrash: "The volume of \(path) has no Trash."
        case .invalidName: "\(path) isn’t a name a file can have."
        case .notTheSameItem: "\(path) is another item now, so it was left as it is."
        case .other:
            if let code = error.errno {
                "\(path) couldn’t be changed: \(String(cString: strerror(code)))."
            } else {
                "\(path) couldn’t be changed."
            }
        }
    }

    // MARK: Views

    /// A bar that fills by bytes copied, or by items done when nothing is copied; one that moves
    /// without filling while the operation hasn't started.
    private func showBar(_ state: OperationState) {
        let progress = state.progress
        let fraction: Double? =
            switch state.phase {
            case .queued, .preparing, .waitingForAnswer: nil
            case .done: 1
            case .running, .paused, .failed, .refused, .cancelled:
                if let total = progress.total, total.bytes > 0 {
                    Double(progress.copied.bytes) / Double(total.bytes)
                } else if let total = progress.total, total.files > 0 {
                    Double(progress.copied.files) / Double(total.files)
                } else if progress.itemCount > 0 {
                    Double(progress.itemsDone) / Double(progress.itemCount)
                } else {
                    nil
                }
            }
        bar.isHidden = state.phase.isFinished
        if let fraction {
            bar.stopAnimation(nil)
            bar.isIndeterminate = false
            bar.doubleValue = min(fraction, 1)
        } else {
            bar.isIndeterminate = true
            bar.startAnimation(nil)
        }
    }

    private func symbol(_ name: String) -> NSImage {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            preconditionFailure("there is no system symbol \(name)")
        }
        return image
    }

    @objc private func pauseClicked(_ sender: NSButton) {
        if phase == .paused { onResume() } else { onPause() }
    }

    @objc private func cancelClicked(_ sender: NSButton) {
        if phase?.isFinished == true { onClear() } else { onCancel() }
    }

    private func buildContent() {
        titleLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.lineBreakMode = .byTruncatingMiddle
        for label in [titleLabel, detailLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        bar.style = .bar
        bar.controlSize = .small
        bar.minValue = 0
        bar.maxValue = 1
        for button in [pauseButton, cancelButton] {
            button.bezelStyle = .accessoryBarAction
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.target = self
        }
        pauseButton.action = #selector(pauseClicked(_:))
        cancelButton.action = #selector(cancelClicked(_:))
        let text = NSStackView(views: [titleLabel, bar, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        // The text, and its bar, take the width the buttons leave.
        text.setHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [text, pauseButton, cancelButton])
        row.orientation = .horizontal
        row.distribution = .fill
        row.alignment = .centerY
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(
            top: 9, left: BarInset.horizontal, bottom: 9, right: BarInset.horizontal)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            bar.widthAnchor.constraint(equalTo: text.widthAnchor),
        ])
    }
}
