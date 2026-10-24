import AppKit
import Browser

/// Answers a `FileOperationQueue`'s questions with `Dialog` sheets: `ConflictSheetController`
/// for a name in use, `ConfirmSheetController` for the other-pane confirm and the
/// delete-immediately question. One sheet shows at a time, on the window `window` gives, which is the most recently
/// active one; questions asked meanwhile wait in order, and wait for a window if none is open.
/// Nothing blocks: each question is an awaited call, so other windows keep their keys.
///
/// A question about an operation a snapshot shows finished, cancelled from the panel or failed
/// by an unmount, closes unanswered, and one asked after that is never shown; the queue drops
/// whatever such a question returns (docs/decisions/0067-operations-panel.md).
@MainActor
final class OperationPrompter {
    /// The sheet on screen.
    enum Sheet {
        case conflict(ConflictSheetController)
        case confirm(ConfirmSheetController)

        @MainActor var panel: NSWindow {
            switch self {
            case .conflict(let sheet): sheet.panel
            case .confirm(let sheet): sheet.panel
            }
        }
    }

    /// A question and the call waiting for its answer.
    private enum Question {
        case conflict(ConflictRequest, CheckedContinuation<ConflictResolution, Never>)
        case confirm(ConfirmRequest, CheckedContinuation<Bool, Never>)

        /// The operation it is about; nil for the other-pane confirm, asked before anything is
        /// queued.
        var operation: FileOperationQueue.ID? {
            switch self {
            case .conflict(let request, _): request.operation
            case .confirm(.deleteImmediately(_, let operation), _): operation
            case .confirm(.otherPane, _): nil
            }
        }

        /// Answers so the queue goes on without acting on it: its operation has finished, so
        /// the queue drops the answer.
        func drop() {
            switch self {
            case .conflict(_, let continuation): continuation.resume(returning: droppedResolution)
            case .confirm(_, let continuation): continuation.resume(returning: false)
            }
        }
    }

    /// What a closed conflict question returns. The queue drops it, since the operation has
    /// finished by then.
    private nonisolated static let droppedResolution = ConflictResolution(
        choice: .skip, appliesToAll: false)

    /// The window a sheet goes on, or nil while none is open.
    var window: @MainActor () -> NSWindow? = { nil }
    /// Shows the first window as a sheet on the second. Tests replace it so nothing is shown.
    var present: @MainActor (NSWindow, NSWindow) -> Void = { sheet, window in
        window.beginSheet(sheet)
    }
    /// Takes a sheet off its window. Tests replace it with `present`.
    var dismiss: @MainActor (NSWindow) -> Void = { sheet in sheet.sheetParent?.endSheet(sheet) }
    /// Cancels the operation of a conflict the user cancelled.
    weak var queue: FileOperationQueue?

    private(set) var shown: Sheet?
    private var shownQuestion: Question?
    /// The window the shown sheet is on.
    private weak var shownOn: NSWindow?
    /// Questions not yet shown, in the order asked.
    private var waiting: [Question] = []
    /// Operations a snapshot has shown finished.
    private var finished: Set<FileOperationQueue.ID> = []

    init() {}

    var waitingCount: Int { waiting.count }

    /// The queue's prompts, answered here.
    nonisolated var prompts: FileOperationQueue.Prompts {
        FileOperationQueue.Prompts(
            resolve: { request in await self.ask(request) },
            confirm: { request in await self.ask(request) })
    }

    /// Notes which operations have finished, and closes their questions.
    func operationsChanged(_ snapshots: [FileOperationQueue.Snapshot]) {
        for snapshot in snapshots where snapshot.state.phase.isFinished {
            finished.insert(snapshot.id)
        }
        let isOver: (Question) -> Bool = { [finished] question in
            question.operation.map(finished.contains) ?? false
        }
        for question in waiting where isOver(question) {
            question.drop()
        }
        waiting.removeAll(where: isOver)
        if let question = shownQuestion, isOver(question) {
            close()
            question.drop()
            showNext()
        }
    }

    /// Shows the first waiting question, unless a sheet is up or no window is open. A window
    /// that opens calls it.
    func showNext() {
        guard shown == nil, !waiting.isEmpty, let window = window() else { return }
        let question = waiting.removeFirst()
        let sheet: Sheet
        switch question {
        case .conflict(let request, let continuation):
            sheet = .conflict(
                ConflictSheetController(request: request) { [weak self] resolution in
                    self?.answer(request, resolution, continuation)
                })
        case .confirm(let request, let continuation):
            sheet = .confirm(
                ConfirmSheetController(request: request) { [weak self] confirmed in
                    self?.close()
                    continuation.resume(returning: confirmed)
                    self?.showNext()
                })
        }
        shown = sheet
        shownQuestion = question
        shownOn = window
        present(sheet.panel, window)
    }

    /// `window` closed: a question shown on it goes back to the front of the line and shows
    /// on the window that is now the most recently active, if any.
    func windowClosed(_ window: NSWindow) {
        guard let question = shownQuestion, shownOn === window else { return }
        close()
        waiting.insert(question, at: 0)
        showNext()
    }

    private func ask(_ request: ConflictRequest) async -> ConflictResolution {
        if finished.contains(request.operation) { return Self.droppedResolution }
        return await withCheckedContinuation { continuation in
            waiting.append(.conflict(request, continuation))
            showNext()
        }
    }

    private func ask(_ request: ConfirmRequest) async -> Bool {
        if case .deleteImmediately(_, let operation) = request, finished.contains(operation) {
            return false
        }
        return await withCheckedContinuation { continuation in
            waiting.append(.confirm(request, continuation))
            showNext()
        }
    }

    /// A conflict's answer; nil cancels its operation, and the question returns once the
    /// queue has finished it, so the answer is dropped.
    private func answer(
        _ request: ConflictRequest, _ resolution: ConflictResolution?,
        _ continuation: CheckedContinuation<ConflictResolution, Never>
    ) {
        close()
        if let resolution {
            continuation.resume(returning: resolution)
        } else {
            guard let queue else {
                preconditionFailure("\(request.operation) was cancelled with no queue to stop it")
            }
            Task {
                await queue.cancel(request.operation)
                continuation.resume(returning: Self.droppedResolution)
            }
        }
        showNext()
    }

    private func close() {
        guard let sheet = shown else {
            preconditionFailure("an operation question closed with no sheet shown")
        }
        dismiss(sheet.panel)
        shown = nil
        shownQuestion = nil
    }
}
