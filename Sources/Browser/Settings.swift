import Foundation

/// The app's preferences, and the only type that reads or writes them. Each is app-wide: every
/// pane applies the same value, and a change reaches every pane. They live in a `UserDefaults`
/// suite the owner passes in, so tests and the UI bench never touch the user's own.
///
/// A key that is missing reads as the preference's default. A value of the wrong type is removed
/// and reads as the default too: stored data has one shape, and UserDefaults' own readers would
/// turn the string "YES" or the number 1 into true, and a number into a string.
@MainActor
public final class Settings {
    enum Key: String {
        case showHidden
        case foldersFirst
        case folderSizes
        case terminalBundleID
        case commanderFKeys
        case hideEmptyOperationsPanel
        case columnWidth
    }

    /// The width a new column of column view gets until one is set: Finder's, the `ColumnWidth`
    /// of its standard column view options.
    public static let defaultColumnWidth = 245.0
    /// The widths a column's grip can drag it to (0096-column-widths.md).
    public nonisolated static let columnWidths: ClosedRange<Double> = 100...1000

    /// What the Settings window says about `commanderFKeys`.
    public static let commanderFKeysHelp =
        "F5 copies and F6 moves the selection to the other pane, F7 makes a new folder and F8 "
        + "moves the selection to the Trash. Hold Fn with them unless “Use F1, F2, etc. keys as "
        + "standard function keys” is on in System Settings ▸ Keyboard."

    /// What the Settings window says about `hideEmptyOperationsPanel`.
    public static let hideEmptyOperationsPanelHelp =
        "The operations panel shows when an operation runs past a second and hides when the last "
        + "one finishes. Window ▸ Operations still shows and hides it."

    /// Whether panes list hidden entries: names starting with a dot, and entries with the hidden
    /// flag (`chflags hidden`). Off by default.
    public var showHidden: Bool {
        didSet { store(showHidden, for: .showHidden, changed: showHidden != oldValue) }
    }
    /// Whether folders come before every other entry in each sort. Off by default.
    public var foldersFirst: Bool {
        didSet { store(foldersFirst, for: .foldersFirst, changed: foldersFirst != oldValue) }
    }
    /// Whether a pane in list view walks each subfolder for its size and shows it, on local and
    /// network volumes alike: Finder's Calculate All Sizes. Off by default, as in Finder, so
    /// browsing reads no more of the disk than the listings.
    public var folderSizes: Bool {
        didSet { store(folderSizes, for: .folderSizes, changed: folderSizes != oldValue) }
    }
    /// The bundle ID of the app Open Terminal Here opens the pane's folder in. Terminal by default.
    public var terminalBundleID: String {
        didSet {
            store(
                terminalBundleID, for: .terminalBundleID,
                changed: terminalBundleID != oldValue)
        }
    }
    /// Whether the Commander F-key preset is on: F5 to F8 run the file commands in
    /// `FileCommands.commanderFKeys`, beside their own keys. Off by default.
    public var commanderFKeys: Bool {
        didSet {
            store(commanderFKeys, for: .commanderFKeys, changed: commanderFKeys != oldValue)
        }
    }

    /// Whether a window's operations panel hides once it has no operations left, as Finder shows
    /// none while idle. Off, the panel stays and says "No operations". On by default.
    public var hideEmptyOperationsPanel: Bool {
        didSet {
            store(
                hideEmptyOperationsPanel, for: .hideEmptyOperationsPanel,
                changed: hideEmptyOperationsPanel != oldValue)
        }
    }

    /// The width, in points, every new column of column view gets, and the preview with them,
    /// in every window. An Option-drag or Option-double-click of a column's grip sets it, as in
    /// Finder; a plain one resizes its column alone (0096-column-widths.md). `defaultColumnWidth`
    /// by default.
    ///
    /// - Precondition: it is within `columnWidths`.
    public var columnWidth: Double {
        didSet {
            precondition(
                Self.columnWidths.contains(columnWidth),
                "column width \(columnWidth) is outside \(Self.columnWidths)")
            store(columnWidth, for: .columnWidth, changed: columnWidth != oldValue)
        }
    }

    /// How long a drag has to hover over a folder before it springs open, as the system's
    /// Spring-loading setting in Accessibility ▸ Pointer Control has it; nil while that setting is
    /// off. The system writes both keys to the global domain, which every suite reads through, and
    /// the app never writes them. A missing key or one of another type reads as the system's
    /// default, on and 0.5 s; it isn't removed, since the key isn't the app's.
    public var springLoadingDelay: Duration? {
        let enabled = defaults.object(forKey: Self.springLoadingEnabledKey)
        if let enabled = enabled as? NSNumber, CFGetTypeID(enabled) == CFBooleanGetTypeID(),
            !enabled.boolValue
        {
            return nil
        }
        let delay = defaults.object(forKey: Self.springLoadingDelayKey)
        guard let delay = delay as? NSNumber, CFGetTypeID(delay) != CFBooleanGetTypeID(),
            delay.doubleValue >= 0, delay.doubleValue.isFinite
        else { return Self.defaultSpringLoadingDelay }
        return .seconds(delay.doubleValue)
    }
    /// The system's keys for its Spring-loading setting, and its default delay.
    static let springLoadingEnabledKey = "com.apple.springing.enabled"
    static let springLoadingDelayKey = "com.apple.springing.delay"
    static let defaultSpringLoadingDelay: Duration = .milliseconds(500)

    private let defaults: UserDefaults
    private var observers: [Observer] = []

    private struct Observer {
        weak var owner: AnyObject?
        let handler: @MainActor () -> Void
    }

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        showHidden = Self.bool(.showHidden, in: defaults) ?? false
        foldersFirst = Self.bool(.foldersFirst, in: defaults) ?? false
        folderSizes = Self.bool(.folderSizes, in: defaults) ?? false
        terminalBundleID = Self.string(.terminalBundleID, in: defaults) ?? "com.apple.Terminal"
        commanderFKeys = Self.bool(.commanderFKeys, in: defaults) ?? false
        hideEmptyOperationsPanel = Self.bool(.hideEmptyOperationsPanel, in: defaults) ?? true
        columnWidth =
            Self.number(.columnWidth, in: defaults, within: Self.columnWidths)
            ?? Self.defaultColumnWidth
    }

    /// Runs `handler` after each change of a setting, for as long as `owner` exists.
    public func observe(for owner: AnyObject, _ handler: @escaping @MainActor () -> Void) {
        observers.append(Observer(owner: owner, handler: handler))
    }

    private func store(_ value: Any, for key: Key, changed: Bool) {
        guard changed else { return }
        defaults.set(value, forKey: key.rawValue)
        observers.removeAll { $0.owner == nil }
        for observer in observers {
            observer.handler()
        }
    }

    /// The Boolean stored under `key`; nil when there is none or it has another type, which is
    /// removed.
    private static func bool(_ key: Key, in defaults: UserDefaults) -> Bool? {
        guard let value = defaults.object(forKey: key.rawValue) else { return nil }
        // A Boolean reads back as an NSNumber, as integers do; only CFBoolean is one.
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue
        }
        defaults.removeObject(forKey: key.rawValue)
        return nil
    }

    /// The number stored under `key`; nil when there is none, it has another type, a Boolean
    /// among them, or it is outside `range`, which is removed.
    private static func number(
        _ key: Key, in defaults: UserDefaults, within range: ClosedRange<Double>
    ) -> Double? {
        guard let value = defaults.object(forKey: key.rawValue) else { return nil }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
            range.contains(number.doubleValue)
        {
            return number.doubleValue
        }
        defaults.removeObject(forKey: key.rawValue)
        return nil
    }

    /// The string stored under `key`; nil when there is none or it has another type, which is
    /// removed.
    private static func string(_ key: Key, in defaults: UserDefaults) -> String? {
        guard let value = defaults.object(forKey: key.rawValue) else { return nil }
        if let string = value as? String {
            return string
        }
        defaults.removeObject(forKey: key.rawValue)
        return nil
    }
}
