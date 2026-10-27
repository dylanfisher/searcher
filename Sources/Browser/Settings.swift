import Foundation

/// The app's preferences, and the only type that reads or writes them. Each is app-wide: every
/// pane applies the same value, and a change reaches every pane. They live in a `UserDefaults`
/// suite the owner passes in, so tests and the UI bench never touch the user's own.
///
/// A key that is missing reads as the preference's default. A value of the wrong type is removed,
/// logged, and reads as the default too: stored data has one shape, and UserDefaults' own readers would
/// turn the string "YES" or the number 1 into true, and a number into a string.
///
/// The user's preferences, those in `preferences`, can also be set in the config file
/// (docs/decisions/0120-config-format.md). Each reads as the value the app stored, then the
/// file's, then its default: a change made in the app is stored and wins over the file, which
/// the app never writes. `configOverrides` lists the app's values that differ from the file's,
/// and `useConfigValue(for:)` removes one.
@MainActor
public final class Settings {
    enum Key: String {
        case showHidden
        case hideDSStore
        case columnsStartAtHome
        case foldersFirst
        case folderSizes
        case terminalBundleID
        case commanderFKeys
        case hideEmptyOperationsPanel
        case columnWidth
        case appearance
        case palettePlace
        case newWindowFrame
        case favorites
        case showsFavoritesInSidebar
        case showsLocationsInSidebar
        case showsWorkspacesInSidebar
        case shortcuts
    }

    /// Where the palette's panel sits on a screen, as Spotlight remembers where it was dragged
    /// (0087-palette-window.md). Each share is of the room the panel leaves on the screen's
    /// visible area, so a place puts the panel wholly on any screen it fits.
    public struct PalettePlace: Equatable, Sendable {
        /// 0 puts the panel against the screen's left edge, 1 against its right.
        public let x: Double
        /// 0 puts the panel's top against the top of the visible area, 1 its bottom against the
        /// bottom.
        public let y: Double

        /// The place at `x` and `y`; nil unless both are within 0 and 1.
        public init?(x: Double, y: Double) {
            guard Self.shares.contains(x), Self.shares.contains(y) else { return nil }
            self.x = x
            self.y = y
        }

        static let shares: ClosedRange<Double> = 0...1
    }

    /// Whether the app is light or dark. Auto follows the system's setting, as it changes.
    public enum Appearance: String, CaseIterable, Sendable {
        case auto
        case light
        case dark
    }

    /// The preferences a user sets, each with its name in the config file, what it accepts and
    /// its default: the one list the config file's parser and template are made from. State the
    /// app keeps by itself, such as the favorites, window frames, the palette's place, and the
    /// shortcuts, which have a syntax of their own, isn't in it.
    public nonisolated static let preferences: [Preference] = [
        Preference(
            .showHidden, "show-hidden", .bool, default: .bool(false),
            summary: "Whether panes list hidden files: names that start with a dot, and files"
                + " with the hidden flag."),
        Preference(
            .hideDSStore, "hide-ds-store", .bool, default: .bool(true),
            summary: "Whether panes leave out .DS_Store files even while hidden files show."),
        Preference(
            .foldersFirst, "folders-first", .bool, default: .bool(false),
            summary: "Whether folders sort before every other item."),
        Preference(
            .folderSizes, "folder-sizes", .bool, default: .bool(false),
            summary: "Whether list view walks each folder for its size, as Finder's Calculate"
                + " All Sizes does."),
        Preference(
            .columnsStartAtHome, "columns-start-at-home", .bool, default: .bool(true),
            summary: "Whether column view starts a folder in your home folder at your home"
                + " folder, as Finder does, rather than at the top of its volume."),
        Preference(
            .columnWidth, "column-width",
            .number(
                isValid: isColumnWidth,
                described:
                    "a whole number from \(Int(columnWidths.lowerBound)) to \(Int(columnWidths.upperBound))"
            ),
            default: .number(defaultColumnWidth),
            summary: "The width, in points, of each new column in column view."),
        Preference(
            .appearance, "appearance", .choice(Appearance.allCases.map(\.rawValue)),
            default: .string(Appearance.auto.rawValue),
            summary: "Light, dark, or auto to follow the system."),
        Preference(
            .terminalBundleID, "terminal-bundle-id", .string,
            default: .string("com.apple.Terminal"),
            summary: "The bundle ID of the app Open Terminal Here opens a folder in."),
        Preference(
            .commanderFKeys, "commander-f-keys", .bool, default: .bool(false),
            summary: "Whether F5 to F8 copy and move to the other pane, make a folder and move"
                + " to the Trash, as in Total Commander."),
        Preference(
            .hideEmptyOperationsPanel, "hide-empty-operations-panel", .bool,
            default: .bool(true),
            summary: "Whether a window's operations panel hides once its operations are done."),
        Preference(
            .showsFavoritesInSidebar, "sidebar-favorites", .bool, default: .bool(true),
            summary: "Whether the sidebar shows Favorites."),
        Preference(
            .showsLocationsInSidebar, "sidebar-locations", .bool, default: .bool(true),
            summary: "Whether the sidebar shows Locations."),
        Preference(
            .showsWorkspacesInSidebar, "sidebar-workspaces", .bool, default: .bool(true),
            summary: "Whether the sidebar shows Workspaces."),
    ]

    /// `preferences` by key.
    nonisolated static let preferencesByKey = Dictionary(
        uniqueKeysWithValues: preferences.map { ($0.key, $0) })

    /// The config file in `home`, where the app reads it.
    public nonisolated static func userConfigFile(home: String) -> URL {
        URL(fileURLWithPath: home, isDirectory: true).appending(path: ".config/searcher/config")
    }

    /// The width a new column of column view gets until one is set, and the width an
    /// Option-double-click puts fitted columns back to (0096-column-widths.md).
    public nonisolated static let defaultColumnWidth = 286.0
    /// The widths a column's grip can drag it to (0096-column-widths.md).
    public nonisolated static let columnWidths: ClosedRange<Double> = 100...1000

    /// Whether `width` is one a column can have: whole points, so the columns sit on the pixel
    /// grid, within `columnWidths` (0096-column-widths.md).
    public nonisolated static func isColumnWidth(_ width: Double) -> Bool {
        columnWidths.contains(width) && width == width.rounded()
    }

    /// The widths the preview's grip can drag it to: up to a column's widest, but no narrower
    /// than keeps the Information rows' titles whole and a word of each value on a line
    /// (0090-preview-column.md).
    public nonisolated static let previewWidths = 200...columnWidths.upperBound

    /// Whether `width` is one the preview can have: a column width within `previewWidths`.
    public nonisolated static func isPreviewWidth(_ width: Double) -> Bool {
        previewWidths.contains(width) && isColumnWidth(width)
    }

    /// The content size a new window gets until a window is resized by hand
    /// (0057-windows-and-tear-out.md).
    public nonisolated static let defaultWindowSize = CGSize(width: 900, height: 600)

    /// Whether `size` is one a window can have: finite and not empty.
    public nonisolated static func isWindowSize(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }

    /// Whether `frame` is one a new window can open at: finite, with a size `isWindowSize(_:)`
    /// accepts.
    public nonisolated static func isWindowFrame(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite && isWindowSize(frame.size)
    }

    /// Whether panes list hidden entries: names starting with a dot, and entries with the hidden
    /// flag (`chflags hidden`). Off by default.
    public var showHidden: Bool {
        get { bool(.showHidden) }
        set { set(.bool(newValue), for: .showHidden) }
    }
    /// Whether panes leave out entries named exactly `.DS_Store` even while `showHidden` lists
    /// the other hidden entries. On by default (0100-appearance-and-ds-store.md). It hides them
    /// from the rows only: copying, moving or trashing a folder takes its `.DS_Store` along.
    public var hideDSStore: Bool {
        get { bool(.hideDSStore) }
        set { set(.bool(newValue), for: .hideDSStore) }
    }
    /// Whether column view's trail for a folder in `home` starts at `home`, as Finder's does,
    /// rather than at the root of the folder's volume. On by default
    /// (0103-column-trail-from-the-root.md).
    public var columnsStartAtHome: Bool {
        get { bool(.columnsStartAtHome) }
        set { set(.bool(newValue), for: .columnsStartAtHome) }
    }
    /// The user's home folder: the folder `~` names in a typed path, a new window opens at and
    /// `columnsStartAtHome` starts trails at. It isn't stored.
    public let home: String
    /// Whether folders come before every other entry in each sort. Off by default.
    public var foldersFirst: Bool {
        get { bool(.foldersFirst) }
        set { set(.bool(newValue), for: .foldersFirst) }
    }
    /// Whether a pane in list view walks each subfolder for its size and shows it, on local and
    /// network volumes alike: Finder's Calculate All Sizes. Off by default, as in Finder, so
    /// browsing reads no more of the disk than the listings.
    public var folderSizes: Bool {
        get { bool(.folderSizes) }
        set { set(.bool(newValue), for: .folderSizes) }
    }
    /// The bundle ID of the app Open Terminal Here opens the pane's folder in. Terminal by default.
    public var terminalBundleID: String {
        get { string(.terminalBundleID) }
        set { set(.string(newValue), for: .terminalBundleID) }
    }
    /// Whether the Commander F-key preset is on: F5 to F8 are the default alternates of the file
    /// commands in `FileCommands.commanderFKeys`. Off by default.
    public var commanderFKeys: Bool {
        get { bool(.commanderFKeys) }
        set { set(.bool(newValue), for: .commanderFKeys) }
    }

    /// Whether a window's operations panel hides once it has no operations left, as Finder shows
    /// none while idle. Off, the panel stays and says "No operations". On by default.
    public var hideEmptyOperationsPanel: Bool {
        get { bool(.hideEmptyOperationsPanel) }
        set { set(.bool(newValue), for: .hideEmptyOperationsPanel) }
    }

    /// The width, in points, every new column of column view gets, and the preview with them,
    /// in every window. An Option-drag or Option-double-click of a column's grip sets it, as in
    /// Finder; a plain one resizes its column alone (0096-column-widths.md). `defaultColumnWidth`
    /// by default.
    ///
    /// - Precondition: `isColumnWidth(_:)` holds for it.
    public var columnWidth: Double {
        get { number(.columnWidth) }
        set {
            precondition(
                Self.isColumnWidth(newValue),
                "column width \(newValue) is not a whole number within \(Self.columnWidths)")
            set(.number(newValue), for: .columnWidth)
        }
    }

    /// Whether the app is light, dark or follows the system. Auto by default.
    public var appearance: Appearance {
        get {
            let name = string(.appearance)
            guard let appearance = Appearance(rawValue: name) else {
                preconditionFailure("appearance holds \(name), which no appearance is named")
            }
            return appearance
        }
        set { set(.string(newValue.rawValue), for: .appearance) }
    }

    /// The sidebar's Favorites, top to bottom, every path distinct by
    /// `Favorite.areDistinct(_:)`; Finder's defaults (`Favorite.defaults(home:)`) until the list
    /// is first changed. Only `Favorites` changes it (docs/decisions/0107-sidebar-favorites.md).
    ///
    /// - Precondition: no path is in it twice.
    public var favorites: [Favorite] {
        didSet {
            precondition(
                Favorite.areDistinct(favorites.map(\.path)), "a favorite is listed twice")
            store(favorites.map(\.stored), for: .favorites, changed: favorites != oldValue)
        }
    }

    /// Whether the sidebar shows its Favorites group. On by default.
    public var showsFavoritesInSidebar: Bool {
        get { bool(.showsFavoritesInSidebar) }
        set { set(.bool(newValue), for: .showsFavoritesInSidebar) }
    }

    /// Whether the sidebar shows its Locations group. On by default.
    public var showsLocationsInSidebar: Bool {
        get { bool(.showsLocationsInSidebar) }
        set { set(.bool(newValue), for: .showsLocationsInSidebar) }
    }

    /// Whether the sidebar shows its Workspaces group. On by default.
    public var showsWorkspacesInSidebar: Bool {
        get { bool(.showsWorkspacesInSidebar) }
        set { set(.bool(newValue), for: .showsWorkspacesInSidebar) }
    }

    /// The user's changes to the commands' chords, by command; empty by default. A command
    /// missing from it keeps its defaults. Each override is kept in one form: a slot set to
    /// what its default gives is `.standard`, and an override with both slots `.standard` is
    /// left out, so it is never written (docs/decisions/0106-primary-and-alternate-shortcuts.md).
    /// `KeyBindings` applies them.
    ///
    /// - Precondition: every ID is a command's in `AppCommands.commands`.
    public var shortcuts: [CommandID: ShortcutOverride] {
        didSet {
            let normal = Self.normalized(shortcuts, dropUnknown: false)
            if normal != shortcuts { shortcuts = normal }
            guard shortcuts != oldValue else { return }
            let key = Key.shortcuts.rawValue
            if shortcuts.isEmpty {
                defaults.removeObject(forKey: key)
                notifyObservers()
            } else {
                store(Self.stored(shortcuts), for: .shortcuts, changed: true)
            }
        }
    }

    /// Where the palette's panel opens, on the screen of the window that opens it; nil for its
    /// own place, centered near the top. Dragging the panel sets it. No pane follows it, so a
    /// change notifies no one.
    public var palettePlace: PalettePlace? {
        didSet {
            guard palettePlace != oldValue else { return }
            let key = Key.palettePlace.rawValue
            if let place = palettePlace {
                defaults.set([place.x, place.y], forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }

    /// The frame a new window opens at: the origin of the window's frame and the size of its
    /// content, as the window last had them when the user finished resizing it by an edge or
    /// moving it by its title bar, as in Finder (0057-windows-and-tear-out.md). Nil until then.
    /// No pane follows it, so a change notifies no one.
    ///
    /// - Precondition: `isWindowFrame(_:)` holds for it.
    public var newWindowFrame: CGRect? {
        didSet {
            guard newWindowFrame != oldValue else { return }
            let key = Key.newWindowFrame.rawValue
            if let frame = newWindowFrame {
                precondition(Self.isWindowFrame(frame), "window frame \(frame) is empty")
                defaults.set(
                    [frame.origin.x, frame.origin.y, frame.width, frame.height], forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }

    /// The content size a new window opens at: that of `newWindowFrame`, `defaultWindowSize`
    /// until one is set.
    public var newWindowSize: CGSize {
        newWindowFrame?.size ?? Self.defaultWindowSize
    }

    /// How long a drag has to hover over a folder before it springs open, as the system's
    /// Spring-loading setting in Accessibility ▸ Pointer Control has it; nil while that setting is
    /// off. The system writes both keys to the global domain, which every suite reads through, and
    /// the app never writes them. A missing key or one of another type reads as the system's
    /// default, on and 0.5 s; it isn't removed, since the key isn't the app's.
    public var springLoadingDelay: Duration? {
        let enabled = defaults.object(forKey: Self.springLoadingEnabledKey)
        if let enabled = enabled as? NSNumber, Self.isBoolean(enabled), !enabled.boolValue {
            return nil
        }
        let delay = defaults.object(forKey: Self.springLoadingDelayKey)
        guard let delay = delay as? NSNumber, !Self.isBoolean(delay),
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

    /// The preferences' values the app stored, which win over the file's.
    private var appValues: [Key: Value] = [:]
    /// The preferences' values the config file last set without an error, which win over the
    /// defaults.
    private var fileValues: [Key: Value] = [:]

    /// The config file, which Open Config File opens; nil for settings that have none, as the
    /// tests' and the UI bench's, where that command is off.
    public let configFile: URL?

    /// What is wrong with the config file as last read, which kept it from being applied; empty
    /// while it applied, or there is none.
    public private(set) var configErrors: [ConfigError] = []

    /// The settings stored in `defaults`, for the user whose home folder is `home`, with
    /// `configFile` as the config file Open Config File opens. `log` gets each stored value
    /// removed for its shape as the settings are read.
    public init(
        defaults: UserDefaults, home: String = NSHomeDirectory(), configFile: URL? = nil,
        log: (String) -> Void
    ) {
        self.defaults = defaults
        self.home = home
        self.configFile = configFile
        for preference in Self.preferences {
            appValues[preference.key] = Self.stored(preference, in: defaults, log: log)
        }
        palettePlace = Self.palettePlace(in: defaults, log: log)
        newWindowFrame = Self.windowFrame(in: defaults, log: log)
        favorites = Self.favorites(in: defaults, log: log) ?? Favorite.defaults(home: home)
        shortcuts = Self.shortcuts(in: defaults, log: log)
    }

    /// Applies what the config file holds: its values, every default when there is no file, or,
    /// for a file with an error, the errors, which leave the values as they were. Tells the
    /// observers when a value or the errors changed.
    public func applyConfig(_ load: ConfigLoad) {
        let before = (Self.preferences.map { value(of: $0.key) }, configErrors)
        switch load.outcome {
        case .missing:
            fileValues = [:]
            configErrors = []
        case .values(let values):
            fileValues = values
            configErrors = []
        case .failed(let errors):
            configErrors = errors
        }
        if before != (Self.preferences.map { value(of: $0.key) }, configErrors) {
            notifyObservers()
        }
    }

    /// Applies `watcher`'s first read of the file before it returns, so windows opened after it
    /// open with the file's values, then each later read as it comes, until the settings or the
    /// watcher are gone. The caller keeps the watcher.
    public func follow(_ watcher: ConfigWatcher) async {
        applyConfig(await watcher.start())
        let loads = watcher.loads
        Task { [weak self] in
            for await load in loads {
                guard let self else { return }
                applyConfig(load)
            }
        }
    }

    /// The preferences whose value set in the app differs from the config file's, in
    /// `preferences` order.
    public var configOverrides: [ConfigOverride] {
        Self.preferences.compactMap { preference in
            guard let app = appValues[preference.key], let file = fileValues[preference.key],
                app != file
            else { return nil }
            return ConfigOverride(
                key: preference.key, name: preference.name, appValue: app, fileValue: file)
        }
    }

    /// Removes the value the app set for `override`'s preference, so the config file's applies.
    public func useConfigValue(for override: ConfigOverride) {
        guard appValues.removeValue(forKey: override.key) != nil else { return }
        defaults.removeObject(forKey: override.key.rawValue)
        notifyObservers()
    }

    /// Runs `handler` after each change of a setting, for as long as `owner` exists.
    public func observe(for owner: AnyObject, _ handler: @escaping @MainActor () -> Void) {
        observers.removeAll { $0.owner == nil }
        observers.append(Observer(owner: owner, handler: handler))
    }

    /// How many observers are kept, those whose owner is gone among them. Tests read it.
    var observerCount: Int { observers.count }

    private func store(_ value: Any, for key: Key, changed: Bool) {
        guard changed else { return }
        defaults.set(value, forKey: key.rawValue)
        notifyObservers()
    }

    /// The value of preference `key`: the app's, the file's, or the default.
    private func value(of key: Key) -> Value {
        guard let preference = Self.preferencesByKey[key] else {
            preconditionFailure("\(key) isn't a preference")
        }
        return appValues[key] ?? fileValues[key] ?? preference.defaultValue
    }

    private func bool(_ key: Key) -> Bool {
        guard case .bool(let bool) = value(of: key) else {
            preconditionFailure("\(key) holds \(value(of: key)), not a Boolean")
        }
        return bool
    }

    private func number(_ key: Key) -> Double {
        guard case .number(let number) = value(of: key) else {
            preconditionFailure("\(key) holds \(value(of: key)), not a number")
        }
        return number
    }

    private func string(_ key: Key) -> String {
        guard case .string(let string) = value(of: key) else {
            preconditionFailure("\(key) holds \(value(of: key)), not a string")
        }
        return string
    }

    /// Stores `value` as the app's for preference `key` when it changes what the preference
    /// reads as, and tells the observers.
    private func set(_ value: Value, for key: Key) {
        guard value != self.value(of: key) else { return }
        appValues[key] = value
        store(value.stored, for: key, changed: true)
    }

    private func notifyObservers() {
        observers.removeAll { $0.owner == nil }
        for observer in observers {
            observer.handler()
        }
    }

    /// Whether `number` is a Boolean. A Boolean reads back as an NSNumber, as integers do; only
    /// CFBoolean is one.
    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// The value stored for `preference`; nil when there is none, or it has another type, a
    /// Boolean for a number among them, or one the preference doesn't accept, which is removed.
    private static func stored(
        _ preference: Preference, in defaults: UserDefaults, log: (String) -> Void
    ) -> Value? {
        let key = preference.key.rawValue
        guard let stored = defaults.object(forKey: key) else { return nil }
        let value: Value? =
            switch stored {
            case let number as NSNumber where isBoolean(number): .bool(number.boolValue)
            case let number as NSNumber: .number(number.doubleValue)
            case let string as String: .string(string)
            default: nil
            }
        if let value, preference.accepts(value) {
            return value
        }
        discard(key, holding: stored, in: defaults, log: log)
        return nil
    }

    /// The palette's place stored under its key, two numbers within 0 and 1; nil when there is
    /// none, or it is anything else, which is removed.
    private static func palettePlace(in defaults: UserDefaults, log: (String) -> Void)
        -> PalettePlace?
    {
        let key = Key.palettePlace.rawValue
        guard let value = defaults.object(forKey: key) else { return nil }
        if let shares = value as? [Any], shares.count == 2,
            let x = shares[0] as? NSNumber, !isBoolean(x),
            let y = shares[1] as? NSNumber, !isBoolean(y),
            let place = PalettePlace(x: x.doubleValue, y: y.doubleValue)
        {
            return place
        }
        discard(key, holding: value, in: defaults, log: log)
        return nil
    }

    /// The window frame stored under its key, four numbers `isWindowFrame(_:)` accepts; nil when
    /// there is none, or it is anything else, which is removed.
    private static func windowFrame(in defaults: UserDefaults, log: (String) -> Void) -> CGRect? {
        let key = Key.newWindowFrame.rawValue
        guard let value = defaults.object(forKey: key) else { return nil }
        if let sides = value as? [Any], sides.count == 4 {
            let numbers = sides.compactMap { side -> Double? in
                guard let number = side as? NSNumber, !isBoolean(number) else { return nil }
                return number.doubleValue
            }
            if numbers.count == 4,
                case let frame = CGRect(
                    x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]),
                isWindowFrame(frame)
            {
                return frame
            }
        }
        discard(key, holding: value, in: defaults, log: log)
        return nil
    }

    /// The favorites stored under their key: a list of `Favorite`s in their stored shape, no path
    /// twice. Nil when there is none, or when it or any item in it has another shape, and the
    /// whole list is removed: one item's shape can't be trusted apart from the list's.
    private static func favorites(in defaults: UserDefaults, log: (String) -> Void) -> [Favorite]? {
        let key = Key.favorites.rawValue
        guard let value = defaults.object(forKey: key) else { return nil }
        if let list = value as? [Any] {
            let favorites = list.compactMap(Favorite.init(stored:))
            if favorites.count == list.count, Favorite.areDistinct(favorites.map(\.path)) {
                return favorites
            }
        }
        discard(key, holding: value, in: defaults, log: log)
        return nil
    }

    /// The shortcuts stored under their key: a dictionary of command IDs to overrides in their
    /// stored shape. Empty when there is none, or when it or any override in it has another
    /// shape, and the whole key is removed, as for `favorites`. An entry for an ID no command
    /// has, as after a command is renamed, is a change of the code rather than bad data: only
    /// that entry is removed.
    private static func shortcuts(in defaults: UserDefaults, log: (String) -> Void) -> [CommandID:
        ShortcutOverride]
    {
        let key = Key.shortcuts.rawValue
        guard let value = defaults.object(forKey: key) else { return [:] }
        if let dictionary = value as? [String: Any] {
            let overrides = dictionary.compactMapValues(ShortcutOverride.init(stored:))
            if overrides.count == dictionary.count {
                let read = Dictionary(
                    uniqueKeysWithValues: overrides.map { (CommandID($0.key), $0.value) })
                let known = normalized(read, dropUnknown: true)
                if known != read {
                    if known.isEmpty {
                        defaults.removeObject(forKey: key)
                    } else {
                        defaults.set(stored(known), forKey: key)
                    }
                    let dropped = Set(read.keys).subtracting(known.keys).map(\.rawValue).sorted()
                    log(
                        "rewrote the setting \(key) without the overrides of \(dropped), which"
                            + " no command has or which change nothing")
                }
                return known
            }
        }
        discard(key, holding: value, in: defaults, log: log)
        return [:]
    }

    /// `shortcuts` with each override `ShortcutOverride.normalized(for:preset:)` and those that
    /// change nothing left out. With `dropUnknown`, an ID no command has is left out too;
    /// without it, one stops at a precondition.
    private static func normalized(
        _ shortcuts: [CommandID: ShortcutOverride], dropUnknown: Bool
    ) -> [CommandID: ShortcutOverride] {
        guard !shortcuts.isEmpty else { return shortcuts }
        let commands = Dictionary(
            AppCommands.commands.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var normal: [CommandID: ShortcutOverride] = [:]
        for (id, override) in shortcuts {
            guard let command = commands[id] else {
                precondition(dropUnknown, "no command has the ID \(id)")
                continue
            }
            let kept = override.normalized(
                for: command, preset: FileCommands.commanderFKeys[id])
            if !kept.isStandard {
                normal[id] = kept
            }
        }
        return normal
    }

    /// `shortcuts` in their stored shape, by the IDs' raw values.
    private static func stored(_ shortcuts: [CommandID: ShortcutOverride]) -> [String: [String:
        String]]
    {
        Dictionary(uniqueKeysWithValues: shortcuts.map { ($0.key.rawValue, $0.value.stored) })
    }

    /// Removes `key`, whose stored `value` has another shape than its setting's, and logs it, so
    /// a setting that reads as its default never does so unexplained.
    private static func discard(
        _ key: String, holding value: Any, in defaults: UserDefaults, log: (String) -> Void
    ) {
        defaults.removeObject(forKey: key)
        log("discarded the setting \(key), which held \(value) of another shape than its own")
    }
}
