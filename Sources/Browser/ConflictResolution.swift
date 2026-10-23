/// The answer to a `ConflictRequest`: what to do with an item whose name the destination folder
/// already has.
public struct ConflictResolution: Equatable, Sendable {
    public enum Choice: Equatable, Sendable {
        /// Put the item in place of the one there, whole: a folder replaces a folder, nothing
        /// is merged. The one there goes to the Trash.
        case replace
        /// Leave both where they are; the item isn't copied or moved.
        case skip
        /// Copy or move the item under Finder's Keep Both name, "name 2.ext".
        case keepBoth
    }

    public let choice: Choice
    /// The same choice answers the operation's later conflicts, which then ask nothing.
    public let appliesToAll: Bool

    public init(choice: Choice, appliesToAll: Bool) {
        self.choice = choice
        self.appliesToAll = appliesToAll
    }
}
