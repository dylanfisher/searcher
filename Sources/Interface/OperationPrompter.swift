import AppKit
import Base
import Browser

/// Answers a `FileOperationQueue`'s questions with `Dialog` sheets: `ConflictSheetController`
/// for a name in use, `ConfirmSheetController` for the other-pane confirm and the
/// delete-immediately question. One sheet shows at a time, on the window `window` gives for its
/// operation: the window that queued it while open, otherwise the most recently active one;
/// questions asked meanwhile wait in order, and wait for a window if none is open.
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

        /// The sheet's buttons, the ones Return, Enter and Esc press among them.
        @MainActor var buttons: [NSButton] {
            switch self {
            case .conflict(let sheet): sheet.dialog.buttons
            case .confirm(let sheet): sheet.alert.buttons
            }
        }
    }

    /// How long a sheet ignores Return, Enter and Esc after it appears. A question can appear
    /// while the user is typing in another window, and the Return meant for that window would
    /// press the sheet's default button, which for a conflict is Replace. Clicks work at once.
    static let keyHold: Duration = .milliseconds(500)

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

    /// The window the sheet of a question about an operation goes on, or nil while none is
    /// open. Given nil for the other-pane confirm, which no operation has yet.
    var window: @MainActor (FileOperationQueue.ID?) -> NSWindow? = { _ in nil }
    /// Shows the first window as a sheet on the second. Tests replace it so nothing is shown.
    var present: @MainActor (NSWindow, NSWindow) -> Void = { sheet, window in
        window.beginSheet(sheet)
    }
    /// Brings the window a sheet is about to show on to the front and makes it key, out of the
    /// Dock if it is minimized, and onto the screen from another Space, as
    /// `makeKeyAndOrderFront` does. The sheet's window may be behind another, since a question
    /// goes on its operation's window, and a sheet no one sees would hold every later question.
    /// Tests replace it so nothing is shown.
    /// When the app isn't active it also bounces the Dock icon once, as Finder does, and
    /// never activates the app.
    var bringForward: @MainActor (NSWindow) -> Void = { window in
        OperationPrompter.bringForward(
            window, appIsActive: NSApp.isActive,
            raise: { window in
                if window.isMiniaturized { window.deminiaturize(nil) }
                window.makeKeyAndOrderFront(nil)
            },
            requestAttention: { _ = NSApp.requestUserAttention(.informationalRequest) })
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

    /// Starts a wait of the given length on the clock, taking the deadline at once.
    private let startWait: DeadlineWait.Start

    /// `clock` times `keyHold`; tests give a manual one.
    init<C: Clock<Duration>>(clock: C = ContinuousClock()) {
        startWait = DeadlineWait.make(on: clock)
    }

    /// Raises `window` with `raise`, and when the app isn't active asks for the user's
    /// attention with `requestAttention` rather than activating it, which would take the keys
    /// from another app.
    static func bringForward(
        _ window: NSWindow, appIsActive: Bool, raise: (NSWindow) -> Void,
        requestAttention: () -> Void
    ) {
        raise(window)
        if !appIsActive { requestAttention() }
    }

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
        guard shown == nil, let first = waiting.first, let window = window(first.operation)
        else { return }
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
        if !window.isKeyWindow { bringForward(window) }
        present(sheet.panel, window)
        holdKeys(of: sheet)
    }

    /// Takes the key equivalents off `sheet`'s buttons for `keyHold`, and the focus off a
    /// focused button, as full keyboard access gives one, so a Return, Enter, Esc or Space typed
    /// for another window as the sheet appears answers nothing.
    private func holdKeys(of sheet: Sheet) {
        let held = sheet.buttons.filter { !$0.keyEquivalent.isEmpty }.map {
            ($0, $0.keyEquivalent)
        }
        for (button, _) in held { button.keyEquivalent = "" }
        let panel = sheet.panel
        let focused = panel.firstResponder as? NSButton
        if focused != nil { panel.makeFirstResponder(panel) }
        let wait = startWait(Self.keyHold)
        Task {
            guard await DeadlineWait.reached(wait) else { return }
            for (button, key) in held { button.keyEquivalent = key }
            if let focused, panel.firstResponder === panel { panel.makeFirstResponder(focused) }
        }
    }

    /// `window` closed: a question shown on it goes back to the front of the line and shows
    /// on the window `window` now gives for it, if any.
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
