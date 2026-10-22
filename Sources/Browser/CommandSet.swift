/// A group of related commands. Add one to `AppCommands.sets` for the app to register it.
public protocol CommandSet: Sendable {
    static var bindings: [CommandBinding] { get }
}
