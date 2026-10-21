/// What a command acts on: the focused pane.
@MainActor
public struct CommandContext {
    public let pane: Pane

    public init(pane: Pane) {
        self.pane = pane
    }
}
