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

    /// The width a new column of column view gets until one is set, and the width an
    /// Option-double-click puts fitted columns back to (0096-column-widths.md).
    public static let defaultColumnWidth = 286.0
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
    /// Whether panes leave out entries named exactly `.DS_Store` even while `showHidden` lists
    /// the other hidden entries. On by default (0100-appearance-and-ds-store.md). It hides them
    /// from the rows only: copying, moving or trashing a folder takes its `.DS_Store` along.
    public var hideDSStore: Bool {
        didSet { store(hideDSStore, for: .hideDSStore, changed: hideDSStore != oldValue) }
    }
    /// Whether column view's trail for a folder in `home` starts at `home`, as Finder's does,
    /// rather than at the root of the folder's volume. On by default
    /// (0103-column-trail-from-the-root.md).
    public var columnsStartAtHome: Bool {
        didSet {
            store(
                columnsStartAtHome, for: .columnsStartAtHome,
                changed: columnsStartAtHome != oldValue)
        }
    }
    /// The user's home folder: the folder `~` names in a typed path, a new window opens at and
    /// `columnsStartAtHome` starts trails at. It isn't stored.
    public let home: String
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
    /// Whether the Commander F-key preset is on: F5 to F8 are the default alternates of the file
    /// commands in `FileCommands.commanderFKeys`. Off by default.
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
    /// - Precondition: `isColumnWidth(_:)` holds for it.
    public var columnWidth: Double {
        didSet {
            precondition(
                Self.isColumnWidth(columnWidth),
                "column width \(columnWidth) is not a whole number within \(Self.columnWidths)")
            store(columnWidth, for: .columnWidth, changed: columnWidth != oldValue)
        }
    }

    /// Whether the app is light, dark or follows the system. Auto by default.
    public var appearance: Appearance {
        didSet {
            store(appearance.rawValue, for: .appearance, changed: appearance != oldValue)
        }
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
        didSet {
            store(
                showsFavoritesInSidebar, for: .showsFavoritesInSidebar,
                changed: showsFavoritesInSidebar != oldValue)
        }
    }

    /// Whether the sidebar shows its Locations group. On by default.
    public var showsLocationsInSidebar: Bool {
        didSet {
            store(
                showsLocationsInSidebar, for: .showsLocationsInSidebar,
                changed: showsLocationsInSidebar != oldValue)
        }
    }

    /// Whether the sidebar shows its Workspaces group. On by default.
    public var showsWorkspacesInSidebar: Bool {
        didSet {
            store(
                showsWorkspacesInSidebar, for: .showsWorkspacesInSidebar,
                changed: showsWorkspacesInSidebar != oldValue)
        }
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

    /// The settings stored in `defaults`, for the user whose home folder is `home`.
    public init(defaults: UserDefaults, home: String = NSHomeDirectory()) {
        self.defaults = defaults
        self.home = home
        showHidden = Self.bool(.showHidden, in: defaults) ?? false
        hideDSStore = Self.bool(.hideDSStore, in: defaults) ?? true
        columnsStartAtHome = Self.bool(.columnsStartAtHome, in: defaults) ?? true
        foldersFirst = Self.bool(.foldersFirst, in: defaults) ?? false
        folderSizes = Self.bool(.folderSizes, in: defaults) ?? false
        terminalBundleID = Self.string(.terminalBundleID, in: defaults) ?? "com.apple.Terminal"
        commanderFKeys = Self.bool(.commanderFKeys, in: defaults) ?? false
        hideEmptyOperationsPanel = Self.bool(.hideEmptyOperationsPanel, in: defaults) ?? true
        columnWidth =
            Self.number(.columnWidth, in: defaults, where: Self.isColumnWidth)
            ?? Self.defaultColumnWidth
        appearance = Self.appearance(in: defaults) ?? .auto
        palettePlace = Self.palettePlace(in: defaults)
        newWindowFrame = Self.windowFrame(in: defaults)
        favorites = Self.favorites(in: defaults) ?? Favorite.defaults(home: home)
        showsFavoritesInSidebar = Self.bool(.showsFavoritesInSidebar, in: defaults) ?? true
        showsLocationsInSidebar = Self.bool(.showsLocationsInSidebar, in: defaults) ?? true
        showsWorkspacesInSidebar = Self.bool(.showsWorkspacesInSidebar, in: defaults) ?? true
        shortcuts = Self.shortcuts(in: defaults)
        // The key `newWindowFrame` replaced (0057-windows-and-tear-out.md).
        defaults.removeObject(forKey: "newWindowSize")
    }

    /// Runs `handler` after each change of a setting, for as long as `owner` exists.
    public func observe(for owner: AnyObject, _ handler: @escaping @MainActor () -> Void) {
        observers.append(Observer(owner: owner, handler: handler))
    }

    private func store(_ value: Any, for key: Key, changed: Bool) {
        guard changed else { return }
        defaults.set(value, forKey: key.rawValue)
        notifyObservers()
    }

    private func notifyObservers() {
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
    /// among them, or one `isValid` rejects, which is removed.
    private static func number(
        _ key: Key, in defaults: UserDefaults, where isValid: (Double) -> Bool
    ) -> Double? {
        guard let value = defaults.object(forKey: key.rawValue) else { return nil }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
            isValid(number.doubleValue)
        {
            return number.doubleValue
        }
        defaults.removeObject(forKey: key.rawValue)
        return nil
    }

    /// The appearance stored under its key; nil when there is none, or it isn't the name of one,
    /// which is removed.
    private static func appearance(in defaults: UserDefaults) -> Appearance? {
        guard let name = string(.appearance, in: defaults) else { return nil }
        if let appearance = Appearance(rawValue: name) {
            return appearance
        }
        defaults.removeObject(forKey: Key.appearance.rawValue)
        return nil
    }

    /// The palette's place stored under its key, two numbers within 0 and 1; nil when there is
    /// none, or it is anything else, which is removed.
    private static func palettePlace(in defaults: UserDefaults) -> PalettePlace? {
        let key = Key.palettePlace.rawValue
        guard let value = defaults.object(forKey: key) else { return nil }
        if let shares = value as? [Any], shares.count == 2,
            let x = shares[0] as? NSNumber, CFGetTypeID(x) != CFBooleanGetTypeID(),
            let y = shares[1] as? NSNumber, CFGetTypeID(y) != CFBooleanGetTypeID(),
            let place = PalettePlace(x: x.doubleValue, y: y.doubleValue)
        {
            return place
        }
        defaults.removeObject(forKey: key)
        return nil
    }

    /// The window frame stored under its key, four numbers `isWindowFrame(_:)` accepts; nil when
    /// there is none, or it is anything else, which is removed.
    private static func windowFrame(in defaults: UserDefaults) -> CGRect? {
        let key = Key.newWindowFrame.rawValue
        guard let value = defaults.object(forKey: key) else { return nil }
        if let sides = value as? [Any], sides.count == 4 {
            let numbers = sides.compactMap { side -> Double? in
                guard let number = side as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID()
                else { return nil }
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
        defaults.removeObject(forKey: key)
        return nil
    }

    /// The favorites stored under their key: a list of `Favorite`s in their stored shape, no path
    /// twice. Nil when there is none, or when it or any item in it has another shape, and the
    /// whole list is removed: one item's shape can't be trusted apart from the list's.
    private static func favorites(in defaults: UserDefaults) -> [Favorite]? {
        let key = Key.favorites.rawValue
        guard let value = defaults.object(forKey: key) else { return nil }
        if let list = value as? [Any] {
            let favorites = list.compactMap(Favorite.init(stored:))
            if favorites.count == list.count, Favorite.areDistinct(favorites.map(\.path)) {
                return favorites
            }
        }
        defaults.removeObject(forKey: key)
        return nil
    }

    /// The shortcuts stored under their key: a dictionary of command IDs to overrides in their
    /// stored shape. Empty when there is none, or when it or any override in it has another
    /// shape, and the whole key is removed, as for `favorites`. An entry for an ID no command
    /// has, as after a command is renamed, is a change of the code rather than bad data: only
    /// that entry is removed.
    private static func shortcuts(in defaults: UserDefaults) -> [CommandID: ShortcutOverride] {
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
                }
                return known
            }
        }
        defaults.removeObject(forKey: key)
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
