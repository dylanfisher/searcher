import AppKit
import Browser

extension BrowserWindowController {
    /// Shows the queue's latest snapshots in the panel.
    public func showOperations(_ snapshots: [FileOperationQueue.Snapshot]) {
        operations.show(snapshots)
    }

    func toggleOperations() {
        userOpenedOperations = operations.view.isHidden
        setOperationsShown(userOpenedOperations)
    }

    /// An operation ran past `OperationsViewController.attentionDelay` or finished in trouble.
    /// Only its own window lists it, so that window shows its panel, whether or not it is the
    /// most recently active.
    func operationNeedsAttention() {
        guard !isClosed else { return }
        setOperationsShown(true)
    }

    func settingsChanged() {
        guard settings.hideEmptyOperationsPanel != hidesEmptyOperations else { return }
        hidesEmptyOperations = settings.hideEmptyOperationsPanel
        hideEmptyOperations()
    }

    /// Hides the panel while it has no rows, if the setting says to and the user didn't open it.
    func hideEmptyOperations() {
        guard settings.hideEmptyOperationsPanel, operations.isEmpty, !userOpenedOperations else {
            return
        }
        setOperationsShown(false)
    }

    private func setOperationsShown(_ isShown: Bool) {
        operations.view.isHidden = !isShown
        panesToBottom.isActive = !isShown
        panesOverOperations.isActive = isShown
    }
}
