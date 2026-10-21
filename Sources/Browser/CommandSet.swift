/// A group of related commands. Add one to `AppCommands.sets` for the app to register it.
public protocol CommandSet {
    static var bindings: [CommandBinding] { get }
}
