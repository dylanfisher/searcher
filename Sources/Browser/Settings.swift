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
    }

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
    /// network volumes alike. On by default.
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
        folderSizes = Self.bool(.folderSizes, in: defaults) ?? true
        terminalBundleID = Self.string(.terminalBundleID, in: defaults) ?? "com.apple.Terminal"
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
