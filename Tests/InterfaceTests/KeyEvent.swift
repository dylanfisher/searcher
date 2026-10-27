import AppKit
import Testing

/// A key event as AppKit builds it for a real key press: `charactersIgnoringModifiers` still
/// has Shift applied, and arrows and function keys arrive as private-use characters.
/// `characters` defaults to `ignoringModifiers`.
@MainActor
func keyEvent(
    _ ignoringModifiers: String, characters: String? = nil, modifiers: NSEvent.ModifierFlags = [],
    keyCode: UInt16 = 0, type: NSEvent.EventType = .keyDown, isARepeat: Bool = false,
    windowNumber: Int = 0, timestamp: TimeInterval = 0
) throws -> NSEvent {
    try #require(
        NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: modifiers, timestamp: timestamp,
            windowNumber: windowNumber, context: nil, characters: characters ?? ignoringModifiers,
            charactersIgnoringModifiers: ignoringModifiers, isARepeat: isARepeat, keyCode: keyCode))
}

/// The character NSEvent uses for a function key such as `NSDownArrowFunctionKey`.
func functionKey(_ code: Int) -> String {
    String(Character(Unicode.Scalar(UInt32(code))!))
}

/// Arrow events carry these flags along with the modifiers held.
let arrowFlags: NSEvent.ModifierFlags = [.numericPad, .function]
