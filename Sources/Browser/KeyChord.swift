/// A key plus the modifiers held with it. Interface converts key events to chords, so this type
/// stays free of AppKit.
public struct KeyChord: Hashable, Sendable, CustomStringConvertible {
    public enum Key: Hashable, Sendable, ExpressibleByExtendedGraphemeClusterLiteral {
        /// The character the key types without Shift: `"g"`, `"1"`, `"."`. `KeyChord.init`
        /// rejects any other spelling; see there.
        case character(Character)
        case up, down, left, right
        /// The Page Up and Page Down keys, which Fn-↑ and Fn-↓ type on a laptop keyboard.
        case pageUp, pageDown
        /// The Home and End keys, which Fn-← and Fn-→ type on a laptop keyboard.
        case home, end
        case tab, `return`, delete, space, escape
        /// F1 to F35. A laptop keyboard sends them with Fn held, unless the system's standard
        /// function keys setting is on; Fn isn't part of the chord.
        case function(Int)

        public init(extendedGraphemeClusterLiteral value: Character) {
            self = .character(value)
        }
    }

    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: UInt8

        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let command = Modifiers(rawValue: 1 << 2)
        public static let shift = Modifiers(rawValue: 1 << 3)
    }

    public let key: Key
    public let modifiers: Modifiers

    /// Traps on a character with another spelling, so that each chord has exactly one and the
    /// registry sees every collision: an uppercase letter is its lowercase plus `.shift`, and
    /// whitespace and control characters (space, tab, return, escape, delete) are named keys.
    public init(_ key: Key, modifiers: Modifiers = []) {
        if case .character(let character) = key {
            precondition(!character.isUppercase, "write \(character) as lowercase plus .shift")
            precondition(
                !Self.isWhitespaceOrControl(character),
                "use a named key for \(character.unicodeScalars.map { $0.escaped(asASCII: true) })")
        }
        if case .function(let number) = key {
            precondition(Self.functionKeys.contains(number), "there is no F\(number) key")
        }
        self.key = key
        self.modifiers = modifiers
    }

    /// The numbers of the F-keys AppKit names, F1 to F35.
    public static let functionKeys = 1...35

    /// Whether `init` takes `character` as a `.character` key.
    public static func accepts(_ character: Character) -> Bool {
        !character.isUppercase && !isWhitespaceOrControl(character)
    }

    private static func isWhitespaceOrControl(_ character: Character) -> Bool {
        character.isWhitespace
            || character.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    /// The spelling the key tables in the docs use, such as "Cmd-Shift-G" or "Ctrl-Opt-Cmd-1".
    public var description: String {
        let names: [(Modifiers, String)] = [
            (.control, "Ctrl"), (.option, "Opt"), (.command, "Cmd"), (.shift, "Shift"),
        ]
        let held = names.filter { modifiers.contains($0.0) }.map(\.1)
        return (held + [keyName]).joined(separator: "-")
    }

    // MARK: Stored spelling

    /// The modifiers in the order `stored` writes them, with their names.
    private static let storedModifiers: [(Modifiers, String)] = [
        (.control, "ctrl"), (.option, "opt"), (.command, "cmd"), (.shift, "shift"),
    ]

    /// The keys `stored` spells by a name rather than a character or an F-key's number.
    private static let namedKeys: [Key] = [
        .up, .down, .left, .right, .pageUp, .pageDown, .home, .end, .tab, .return, .delete, .space,
        .escape,
    ]

    /// The chord as `Settings` stores it: the modifiers held, in the order ctrl, opt, cmd,
    /// shift, then the key, joined by "+", such as "cmd+shift+k", "cmd++", "f5" or "pageup".
    /// `init?(stored:)` reads it back (docs/decisions/0106-primary-and-alternate-shortcuts.md).
    public var stored: String {
        let held = Self.storedModifiers.filter { modifiers.contains($0.0) }.map(\.1)
        return (held + [Self.storedName(of: key)]).joined(separator: "+")
    }

    /// The chord `stored` spells; nil for a string `stored` wouldn't write, such as
    /// "shift+cmd+k", "cmd+K", "Cmd+k" or "f36", so each chord reads back from one spelling.
    public init?(stored: String) {
        // The key follows the last "+", unless the key is "+" itself.
        let name: Substring
        let held: Substring
        if stored.hasSuffix("++") {
            name = "+"
            held = stored.dropLast(2)
        } else if stored != "+", let plus = stored.lastIndex(of: "+") {
            name = stored[stored.index(after: plus)...]
            held = stored[..<plus]
        } else {
            name = Substring(stored)
            held = ""
        }
        var modifiers: Modifiers = []
        if !held.isEmpty {
            for part in held.split(separator: "+", omittingEmptySubsequences: false) {
                guard let modifier = Self.storedModifiers.first(where: { $0.1 == part }) else {
                    return nil
                }
                modifiers.insert(modifier.0)
            }
        }
        guard let key = Self.key(storedName: name) else { return nil }
        let chord = KeyChord(key, modifiers: modifiers)
        guard chord.stored == stored else { return nil }
        self = chord
    }

    private static func storedName(of key: Key) -> String {
        switch key {
        case .character(let character): String(character)
        case .up: "up"
        case .down: "down"
        case .left: "left"
        case .right: "right"
        case .pageUp: "pageup"
        case .pageDown: "pagedown"
        case .home: "home"
        case .end: "end"
        case .tab: "tab"
        case .return: "return"
        case .delete: "delete"
        case .space: "space"
        case .escape: "escape"
        case .function(let number): "f\(number)"
        }
    }

    /// The key `storedName(of:)` gives `name`; nil for none.
    private static func key(storedName name: Substring) -> Key? {
        if let named = namedKeys.first(where: { storedName(of: $0) == name }) {
            return named
        }
        if name.count > 1, name.first == "f", let number = Int(name.dropFirst()),
            functionKeys.contains(number)
        {
            return .function(number)
        }
        guard name.count == 1, let character = name.first, accepts(character) else { return nil }
        return .character(character)
    }

    private var keyName: String {
        switch key {
        case .character(let character): character.uppercased()
        case .up: "↑"
        case .down: "↓"
        case .left: "←"
        case .right: "→"
        // Fn-↑ and Fn-↓ type these on a laptop keyboard.
        case .pageUp: "Page Up"
        case .pageDown: "Page Down"
        case .home: "Home"
        case .end: "End"
        case .tab: "Tab"
        case .return: "Return"
        case .delete: "Delete"
        case .space: "Space"
        case .escape: "Esc"
        case .function(let number): "F\(number)"
        }
    }
}
