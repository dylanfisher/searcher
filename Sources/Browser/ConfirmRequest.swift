/// A yes-or-no question before something happens, for Interface to word and show: what would
/// happen, and where. Nothing happens until it is answered yes.
public enum ConfirmRequest: Equatable, Sendable {
    /// A copy or a move to the other pane's folder, asked by its command before it queues the
    /// operation.
    case otherPane(FileOperation)
    /// Deleting these items at once, because their volume has no Trash: the items of a trash,
    /// or the items a replace would put the new ones in place of. Asked by the queue, once per
    /// operation, and `operation` waits for the answer; no ends it as cancelled.
    case deleteImmediately([String], operation: FileOperationQueue.ID)
}
