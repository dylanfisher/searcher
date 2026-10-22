/// A key plus the modifiers held with it. Interface converts key events to chords, so this type
/// stays free of AppKit.
public struct KeyChord: Hashable, Sendable, CustomStringConvertible {
    public enum Key: Hashable, Sendable, ExpressibleByExtendedGraphemeClusterLiteral {
        /// The character the key types without Shift: `"g"`, `"1"`, `"."`. `KeyChord.init`
        /// rejects any other spelling; see there.
        case character(Character)
        case up, down, left, right
        case tab, `return`, delete, space, escape

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
        self.key = key
        self.modifiers = modifiers
    }

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

    private var keyName: String {
        switch key {
        case .character(let character): character.uppercased()
        case .up: "↑"
        case .down: "↓"
        case .left: "←"
        case .right: "→"
        case .tab: "Tab"
        case .return: "Return"
        case .delete: "Delete"
        case .space: "Space"
        case .escape: "Esc"
        }
    }
}
