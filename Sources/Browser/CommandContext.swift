/// What a command acts on: the focused pane, and the views around it that Browser can't reach.
@MainActor
public struct CommandContext {
    public let pane: Pane
    /// Opens the Quick Look panel on the pane's selection, or closes it. Interface supplies it,
    /// since the panel is AppKit's; a context made without one traps when the command runs.
    public let toggleQuickLook: @MainActor () -> Void
    /// Asks the user for a folder to show in `pane`, in the pane's window. Only the view that runs
    /// commands can show one; a context built without it traps when Go to folder runs.
    public let askForFolder: @MainActor () -> Void

    public init(
        pane: Pane,
        toggleQuickLook: @escaping @MainActor () -> Void = {
            preconditionFailure("this command context has no Quick Look panel")
        },
        askForFolder: @escaping @MainActor () -> Void = {
            preconditionFailure("this command context can't ask for a folder")
        }
    ) {
        self.pane = pane
        self.toggleQuickLook = toggleQuickLook
        self.askForFolder = askForFolder
    }
}
