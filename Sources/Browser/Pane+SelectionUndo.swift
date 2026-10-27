import Base
import Foundation

extension Pane {
    /// The tab whose selection history the pane's changes go into: its own, or its trail owner's
    /// for a column. Nil for a pane in no tab, as a bench or a test makes one; Undo and Redo
    /// Selection are off there.
    var tab: Tab? { containingTrail?.owner.holdingTab ?? holdingTab }

    /// Selects `selection`, a step resolved against the rows (`restorable`), for Undo or Redo
    /// Selection, recording nothing; `owner` is this pane, or the pane whose trail this column is
    /// in. A column without the keys takes them first, adding nothing to Back: Undo Selection
    /// puts the keys back in a trail the pane never left.
    func restore(_ selection: Selection, in owner: Pane) {
        if let trail = owner.columnTrail,
            let column = trail.columns.first(where: { $0.pane === self })
        {
            owner.isSteppingHistory = true
            defer { owner.isSteppingHistory = false }
            trail.focus(column, recordingAs: nil)
        }
        set(selection, recordingAs: nil)
    }

    /// Starts the trail again at `location`, a folder of it whose column has closed, as a
    /// navigation does, keeping the columns above it, with `selection` in its column, recording
    /// nothing: for Undo and Redo Selection, which put the keys back in a trail the pane never
    /// left, so nothing goes to Back and the selection steps stay. The selection's names wait
    /// for the column's rows, as any selection made before them does.
    func reopenColumn(at location: Location, selecting selection: Selection) {
        guard columnTrail != nil else { preconditionFailure("reopening a column in list mode") }
        move(to: location, selection: selection, isNavigation: false)
        commandPane.select(selection, recordingAs: nil)
    }

    /// `step` resolved against the rows shown, or nil when it would change nothing: unless it
    /// `movingKeys` to this pane or column, when it would select nothing listed and has no
    /// listed cursor, or would select what is selected now. A complete listing drops the names
    /// it doesn't have. Rows not listed yet, as in a column just opened, can't tell: the step
    /// is kept by name until they land, and is nil only when it is the selection now. Work per
    /// entry of the step, on the main thread: a step is restored at once, as a key's move is
    /// shown.
    func restorable(_ step: Selection, movingKeys: Bool) -> Selection? {
        guard let listing = state.listing else {
            return movingKeys || step != selection ? step : nil
        }
        let complete = if case .loaded = state { true } else { false }
        let restored = onMain { step.resolved(in: listing, after: .loaded(complete: complete)) }
        if movingKeys { return restored }
        guard !restored.isEmpty || restored.cursorRow(in: listing) != nil,
            restored != selection
        else { return nil }
        return restored
    }
}
