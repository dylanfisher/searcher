/// A direction to move focus, a pane or a divider in.
public enum Direction: Sendable, CaseIterable {
    case left, right, up, down

    /// The axis of the splits that moving this way crosses.
    public var axis: Axis {
        switch self {
        case .left, .right: .horizontal
        case .up, .down: .vertical
        }
    }
}
