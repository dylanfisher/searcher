import AppKit
import Browser
import Observation
import SwiftUI

/// What the Shortcuts pane shows and does: the commands grouped as the menus are, each with its
/// two slots, and the user's changes written to `Settings.shortcuts`, so the menus and the keys
/// follow at once. Every rule comes from `KeyBindings`; this only shows its answers
/// (docs/decisions/0106-primary-and-alternate-shortcuts.md).
@MainActor @Observable
final class ShortcutsSettings {
    /// One command's row.
    struct Row: Identifiable, Equatable {
        let id: CommandID
        let title: String
        let chords: KeyBindings.Chords
        /// Whether the primary is an Edit item's fixed chord, which can't be changed.
        let primaryIsFixed: Bool
        /// Whether the user changed the command's chords in the app, so Reset has something to
        /// do.
        let isChanged: Bool
        /// Where the command's chords work, when that isn't everywhere.
        let note: String?
        /// The slots whose chord, or lack of one, is the config file's, primary first.
        let fileSlots: [ShortcutOverride.Position]
        /// The slots set in the app to other than the config file sets them.
        let configOverrides: [Browser.Settings.ShortcutConfigOverride]
    }

    struct Section: Identifiable, Equatable {
        var id: String { title }
        let title: String
        let rows: [Row]
    }

    /// Why a row's last recording wasn't kept, or the conflict waiting on Replace or Cancel.
    struct Notice: Equatable {
        enum Kind: Equatable {
            /// Another command has the chord; Replace takes it.
            case taken(by: Command, candidates: [KeyChord])
            /// A standard menu item, such as Quit, has the chord.
            case reserved
            /// The chord is a command's fixed primary.
            case fixed(to: Command)
            /// The primary is fixed.
            case fixedPrimary
        }

        let position: ShortcutOverride.Position
        let chord: KeyChord?
        let kind: Kind

        /// What the row says.
        var message: String {
            let keys = chord?.symbols ?? "That shortcut"
            return switch kind {
            case .taken(let owner, _): "\(keys) is used by \(owner.title)."
            case .reserved: "\(keys) belongs to a menu item that can't be changed, such as Quit."
            case .fixed(let owner):
                "\(keys) stays with \(owner.title) so text fields keep it, and can't be used here."
            case .fixedPrimary: "This primary shortcut stays fixed so text fields keep it."
            }
        }

        var isConflict: Bool {
            if case .taken = kind { return true }
            return false
        }
    }

    /// What a row's note says when its chords work in the file list only.
    static let listOnlyNote = "Works in the file list only."
    static let plainKeyNote = "A shortcut without ⌘, ⌃ or ⌥ works in the file list only."

    let settings: Browser.Settings
    /// The text the rows are filtered by: a title or chord symbols such as "⇧⌘P".
    var search = ""
    private(set) var notices: [CommandID: Notice] = [:]
    private(set) var bindings: KeyBindings
    /// Posts an accessibility notification. Tests replace it to record what would be posted.
    @ObservationIgnored var postAccessibility:
        @MainActor (
            Any, NSAccessibility.Notification, [NSAccessibility.NotificationUserInfoKey: Any]?
        )
            -> Void = { element, notification, userInfo in
                NSAccessibility.post(
                    element: element, notification: notification, userInfo: userInfo)
            }

    init(settings: Browser.Settings) {
        self.settings = settings
        bindings = PaneViewController.keyBindings(for: settings)
        settings.observe(for: self) { [weak self] in
            guard let self else { return }
            bindings = PaneViewController.keyBindings(for: self.settings)
        }
    }

    /// The menus' commands as rows, those matching `search` only, in sections with rows.
    var sections: [Section] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return MainMenuBuilder.commandsByMenu.compactMap { menu, ids in
            let rows = ids.map(row).filter { matches($0, query) }
            return rows.isEmpty ? nil : Section(title: menu, rows: rows)
        }
    }

    var canResetAll: Bool { !settings.shortcuts.isEmpty }

    /// Takes what a slot's recorder recorded.
    func record(
        _ recording: ShortcutRecorderField.Recording, for id: CommandID,
        at position: ShortcutOverride.Position
    ) {
        switch recording {
        case .removed:
            apply(bindings.remove(from: id, at: position), for: id, at: position, chord: nil)
        case .chords(let candidates):
            apply(
                bindings.assign(candidates, to: id, at: position), for: id, at: position,
                chord: candidates.last, candidates: candidates)
        }
    }

    /// Takes the chord of the row's conflict from the command that has it.
    func replace(_ id: CommandID) {
        guard let notice = notices[id], case .taken(_, let candidates) = notice.kind else {
            preconditionFailure("\(id) has no conflict to replace")
        }
        apply(
            bindings.assign(candidates, to: id, at: notice.position, replacing: true), for: id,
            at: notice.position, chord: notice.chord, candidates: candidates)
    }

    /// Drops the row's notice and leaves its chords as they are.
    func cancel(_ id: CommandID) {
        notices[id] = nil
    }

    /// Removes the command's overrides made in the app, which gives it the config file's slots,
    /// and its defaults for the others.
    func reset(_ id: CommandID) {
        notices[id] = nil
        settings.shortcuts[id] = nil
    }

    /// Removes every override made in the app, which gives each command the config file's
    /// slots, and its defaults for the others. The file is never written.
    func resetAll() {
        notices = [:]
        settings.shortcuts = [:]
    }

    /// Removes the app's override of `override`'s slot, so the config file's applies.
    func useConfigValue(for override: Browser.Settings.ShortcutConfigOverride) {
        notices[override.command] = nil
        settings.useConfigShortcut(for: override)
    }

    /// What a row says of a slot the app sets over the config file's: "Searcher has ⌃⌥⌘L as
    /// the alternate; the config file has ⌃⌥⌘J."
    static func note(for override: Browser.Settings.ShortcutConfigOverride) -> String {
        func spelled(_ slot: ShortcutOverride.Slot) -> String {
            guard case .chord(let chord) = slot else { return "none" }
            return chord.symbols
        }
        return "Searcher has \(spelled(override.appSlot)) as the \(override.position.rawValue);"
            + " the config file has \(spelled(override.fileSlot))."
    }

    /// What a row says of the slots it has from the config file; nil for none.
    static func fileNote(for row: Row) -> String? {
        switch row.fileSlots.count {
        case 0: nil
        case 1: "The config file sets the \(row.fileSlots[0].rawValue) shortcut."
        default: "The config file sets both shortcuts."
        }
    }

    private func apply(
        _ assignment: KeyBindings.Assignment, for id: CommandID,
        at position: ShortcutOverride.Position, chord: KeyChord?, candidates: [KeyChord] = []
    ) {
        let kind: Notice.Kind
        switch assignment {
        case .assigned(let overrides):
            notices[id] = nil
            settings.shortcuts = overrides
            return
        case .taken(let owner): kind = .taken(by: owner, candidates: candidates)
        case .reserved: kind = .reserved
        case .fixed(let owner): kind = .fixed(to: owner)
        case .fixedPrimary: kind = .fixedPrimary
        }
        let notice = Notice(position: position, chord: chord, kind: kind)
        notices[id] = notice
        // The notice shows below the row, away from the recorder VoiceOver is on, so it is read
        // out, at high priority so the recorder's new value doesn't drop it.
        postAccessibility(
            NSApp as Any, .announcementRequested,
            [
                .announcement: notice.message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
    }

    private func row(_ id: CommandID) -> Row {
        guard let command = bindings.registry.command(for: id) else {
            preconditionFailure("the menus list \(id), which the registry doesn't have")
        }
        let chords = bindings.chords(of: id)
        let note: String? =
            if MainMenuBuilder.commandsWithoutMenuChords.contains(id) {
                Self.listOnlyNote
            } else if [chords.primary, chords.alternate].contains(where: {
                $0.map { !$0.canBeKeyEquivalent } ?? false
            }) {
                Self.plainKeyNote
            } else {
                nil
            }
        let app = settings.shortcuts[id] ?? ShortcutOverride()
        let file = settings.configShortcuts[id] ?? ShortcutOverride()
        // A file chord another command's app override took isn't the file's on this row.
        let fileSlots = ShortcutOverride.Position.allCases.filter { position in
            guard app[position] == .standard else { return false }
            switch file[position] {
            case .standard: return false
            case .removed: return chords[position] == nil
            case .chord(let chord): return chords[position] == chord
            }
        }
        return Row(
            id: id, title: command.title, chords: chords,
            primaryIsFixed: bindings.fixed.values.contains(id),
            isChanged: settings.shortcuts[id] != nil, note: note, fileSlots: fileSlots,
            configOverrides: settings.shortcutConfigOverrides(of: id))
    }

    private func matches(_ row: Row, _ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        if row.title.localizedCaseInsensitiveContains(query) { return true }
        return [row.chords.primary, row.chords.alternate].contains {
            $0?.symbols.localizedCaseInsensitiveContains(query) ?? false
        }
    }
}

/// The Shortcuts pane of the Settings window: a search field, the commands grouped as the menus
/// are with a recorder for each slot, and Reset All.
struct ShortcutsSettingsView: View {
    @Bindable var model: ShortcutsSettings

    static let recorderWidth: CGFloat = 120

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search by name or keys", text: $model.search)
                .textFieldStyle(.roundedBorder)
                .padding(12)
            HStack {
                Text("Command")
                Spacer()
                Text("Primary").frame(width: Self.recorderWidth)
                Text("Alternate").frame(width: Self.recorderWidth)
                Color.clear.frame(width: ShortcutRow.resetWidth, height: 1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .padding(.bottom, 4)
            List {
                ForEach(model.sections) { section in
                    Section(section.title) {
                        ForEach(section.rows) { row in
                            ShortcutRow(model: model, row: row, notice: model.notices[row.id])
                        }
                    }
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Reset All") { model.resetAll() }
                    .disabled(!model.canResetAll)
            }
            .padding(12)
        }
    }
}

/// One command: its title, a recorder for each slot, Reset, and what the last recording found.
private struct ShortcutRow: View {
    let model: ShortcutsSettings
    let row: ShortcutsSettings.Row
    let notice: ShortcutsSettings.Notice?

    static let resetWidth: CGFloat = 56

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                recorder(.primary, isEnabled: !row.primaryIsFixed)
                recorder(.alternate, isEnabled: true)
                Button("Reset") { model.reset(row.id) }
                    .controlSize(.small)
                    .disabled(!row.isChanged)
                    .frame(width: Self.resetWidth)
            }
            if let note = row.note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            if row.primaryIsFixed {
                Text("The primary shortcut is the Edit menu's and can't be changed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let fileNote = ShortcutsSettings.fileNote(for: row) {
                Text(fileNote).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(row.configOverrides, id: \.position) { override in
                HStack {
                    Text(ShortcutsSettings.note(for: override))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Use Config File Value") { model.useConfigValue(for: override) }
                        .controlSize(.small)
                }
            }
            if let notice {
                HStack {
                    Text(notice.message)
                        .font(.caption)
                        .foregroundStyle(notice.isConflict ? Color.primary : Color.red)
                    Spacer()
                    if notice.isConflict {
                        Button("Replace") { model.replace(row.id) }.controlSize(.small)
                        Button("Cancel") { model.cancel(row.id) }.controlSize(.small)
                    } else {
                        Button("OK") { model.cancel(row.id) }.controlSize(.small)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func recorder(_ position: ShortcutOverride.Position, isEnabled: Bool) -> some View {
        ShortcutRecorder(
            chord: row.chords[position], label: "\(row.title), \(position.rawValue) shortcut",
            isEnabled: isEnabled
        ) { recording in
            model.record(recording, for: row.id, at: position)
        }
        .frame(width: ShortcutsSettingsView.recorderWidth, height: ShortcutRecorderField.height)
    }
}
