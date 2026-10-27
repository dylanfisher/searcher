import AppKit
import Base
import Browser
import Interface
import os

extension UIBench {
    /// A synthetic key press: what the event types, its key code and the flags a real press of
    /// it carries.
    struct Key {
        let characters: String
        let keyCode: UInt16
        let flags: NSEvent.ModifierFlags

        /// Arrow events carry `.numericPad` and `.function` along with the modifiers held.
        static let down = Key(
            characters: function(NSDownArrowFunctionKey), keyCode: 125,
            flags: [.numericPad, .function])
        /// The Home and End keys of a full keyboard, which Fn-← and Fn-→ also type.
        static let home = Key(
            characters: function(NSHomeFunctionKey), keyCode: 115, flags: .function)
        static let end = Key(
            characters: function(NSEndFunctionKey), keyCode: 119, flags: .function)
        static let controlShiftDown = Key(
            characters: function(NSDownArrowFunctionKey), keyCode: 125,
            flags: [.numericPad, .function, .control, .shift])
        static let shiftDown = Key(
            characters: function(NSDownArrowFunctionKey), keyCode: 125,
            flags: [.numericPad, .function, .shift])
        static let right = Key(
            characters: function(NSRightArrowFunctionKey), keyCode: 124,
            flags: [.numericPad, .function])
        static let left = Key(
            characters: function(NSLeftArrowFunctionKey), keyCode: 123,
            flags: [.numericPad, .function])
        /// Fn-↓ types Page Down.
        static let pageDown = Key(
            characters: function(NSPageDownFunctionKey), keyCode: 121, flags: .function)
        static let commandA = Key(characters: "a", keyCode: 0, flags: .command)
        /// Shift applies to the character: a US keyboard types ">".
        static let commandShiftPeriod = Key(
            characters: ">", keyCode: 47, flags: [.command, .shift])
        static let sortBySize = Key(characters: "2", keyCode: 19, flags: [.control, .option])
        static let sortByName = Key(characters: "1", keyCode: 18, flags: [.control, .option])
        static let commandF = Key(characters: "f", keyCode: 3, flags: .command)
        /// Shift applies to the letter.
        static let splitRight = Key(characters: "T", keyCode: 17, flags: [.command, .shift])
        /// The key is read without Option, so "T" as for Split Right.
        static let splitDown = Key(characters: "T", keyCode: 17, flags: [.option, .shift])

        /// Cmd-Opt-Shift and an arrow: the tiling key that focuses the pane that way.
        static func focus(_ direction: Direction) -> Key {
            let flags: NSEvent.ModifierFlags = [
                .numericPad, .function, .command, .option, .shift,
            ]
            return switch direction {
            case .left:
                Key(characters: function(NSLeftArrowFunctionKey), keyCode: 123, flags: flags)
            case .right:
                Key(characters: function(NSRightArrowFunctionKey), keyCode: 124, flags: flags)
            case .down:
                Key(characters: function(NSDownArrowFunctionKey), keyCode: 125, flags: flags)
            case .up:
                Key(characters: function(NSUpArrowFunctionKey), keyCode: 126, flags: flags)
            }
        }
        static let escape = Key(characters: "\u{1B}", keyCode: 53, flags: [])
        /// The key is read without Option, so "l".
        static let toggleOperations = Key(characters: "l", keyCode: 37, flags: [.command, .option])

        /// A press of `chord`, a letter or punctuation key with modifiers. The key code is left at
        /// 0: dispatch reads only the characters and the modifier flags
        /// (`KeyChord.candidates(for:)`); only shifted punctuation reads the key itself.
        static func pressing(_ chord: KeyChord) throws -> Key {
            guard case .character(let character) = chord.key,
                !(chord.modifiers.contains(.shift)
                    && (character.isPunctuation || character.isSymbol))
            else { throw Failure("the bench can't press \(chord) without its key code") }
            var flags: NSEvent.ModifierFlags = []
            if chord.modifiers.contains(.control) { flags.insert(.control) }
            if chord.modifiers.contains(.option) { flags.insert(.option) }
            if chord.modifiers.contains(.command) { flags.insert(.command) }
            if chord.modifiers.contains(.shift) { flags.insert(.shift) }
            return Key(characters: String(character), keyCode: 0, flags: flags)
        }

        /// The character AppKit types for a function key such as `NSDownArrowFunctionKey`.
        private static func function(_ code: Int) -> String {
            String(Character(Unicode.Scalar(UInt32(code))!))
        }
    }

    /// Sends each key to the list's window in turn, each timed from the event's timestamp to the
    /// frame that shows its change, as a span named `name`.
    func press(_ keys: [Key], _ name: StaticString) async throws -> [Double] {
        let window = try requireWindow()
        var samples: [Double] = []
        for key in keys {
            try requireVisible()
            let interval = begin(name)
            let event = try keyEvent(key, in: window)
            // Straight to the window: the app isn't active, so its key window gets no keys from
            // the event queue.
            window.sendEvent(event)
            samples.append(try await frame(from: event.timestamp, name, interval))
        }
        return samples
    }

    /// A press of `key` for `window`, stamped now.
    func keyEvent(_ key: Key, in window: NSWindow) throws -> NSEvent {
        guard
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: key.flags,
                timestamp: FrameCommitTimer.now, windowNumber: window.windowNumber,
                context: nil, characters: key.characters,
                charactersIgnoringModifiers: key.characters, isARepeat: false,
                keyCode: key.keyCode)
        else { throw Failure("could not make a key event for \(key.characters)") }
        return event
    }

    /// Notes in `lastWake` each time the main run loop wakes, which starts the pass that takes a
    /// worker's result in, until the observer is invalidated.
    func watchWakes() -> CFRunLoopObserver {
        let wake = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.afterWaiting.rawValue, true, 0
        ) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.lastWake = FrameCommitTimer.now }
        }
        guard let wake else { preconditionFailure("CFRunLoopObserverCreate failed") }
        CFRunLoopAddObserver(CFRunLoopGetMain(), wake, .commonModes)
        return wake
    }

    func cursorRow() throws -> Int {
        let pane = try requirePane()
        guard let listing = pane.state.listing, let row = pane.selection.cursorRow(in: listing)
        else { throw Failure("the pane has no cursor row: \(pane.selection)") }
        return row
    }

    /// Throws unless `row` alone is selected, with the cursor on it.
    func expectCursor(atRow row: Int, after presses: String) throws {
        try expectCursor(atRow: row, in: try requirePane(), after: presses)
    }

    /// Throws unless `row` alone is selected in `pane`, with the cursor on it.
    func expectCursor(atRow row: Int, in pane: Pane, after presses: String) throws {
        guard let listing = pane.state.listing, row < listing.count,
            pane.selection
                == Selection([ExactName(listing[row].name)], cursor: ExactName(listing[row].name))
        else {
            throw Failure(
                "\(presses) should select row \(row) alone, but the selection is \(pane.selection)")
        }
    }
}
