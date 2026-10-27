import AppKit
import Browser

extension BrowserWindowController {
    /// Shows the palette over the window, with the keys in its field, unless it already shows.
    /// It lists the saved workspaces, the visited folders and the folders open panes show, the
    /// folders of a typed path, and the commands of the focused pane's table, a command that is
    /// off there greyed; then `extra`'s items, which the UI bench adds. A folder opens in the
    /// focused pane, a command runs as its key would, and a saved workspace opens or comes to
    /// the front.
    public func showPalette(adding extra: [any PaletteSource] = []) {
        guard palette == nil, !isClosed, !workspace.isClosed, let window else { return }
        let workspace = workspace
        let focusedPane: @MainActor @Sendable () -> Pane = { workspace.selectedTab.focusedPane }
        let visits = folderVisits
        let history: @MainActor () -> FolderHistory = { visits?.history ?? FolderHistory() }
        let home = settings.home
        let sources: [any PaletteSource] = [
            WorkspaceSource(list: workspaces) { [weak self] id in self?.sidebar.open(id) },
            FolderSource(
                history: history, workspaces: workspaces, focusedPane: focusedPane, home: home),
            PathSource(
                service: focusedPane().service, history: history, focusedPane: focusedPane,
                home: home),
            CommandSource(
                registry: { [weak self] in
                    // The window closes its palette as it closes.
                    guard let self else { preconditionFailure("the palette outlived its window") }
                    return focusedTable.registry
                },
                run: { [weak self] id in self?.runFromPalette(id) }),
        ]
        let controller = PaletteWindowController(
            palette: Palette(sources: sources + extra), settings: settings)
        controller.viewController.isEnabled = { [weak self] item in
            guard case .command(let id) = item.id else { return true }
            return self?.canRunFromPalette(id) ?? false
        }
        present(
            controller, closedBy: WindowCommands.showPalette.id,
            switchingTo: WindowCommands.goToItem.id, over: window)
    }

    /// Shows the palette over the window in Go to Item mode, unless a palette already shows. It
    /// lists the rows of the focused pane, or of its focused column and the folder selected
    /// there, as the pane shows them, and selects the chosen one there with its row in the middle
    /// of the view (docs/decisions/0101-go-to-item.md).
    func showItemPalette() {
        guard palette == nil, !isClosed, !workspace.isClosed, let window else { return }
        let source = EntrySource(pane: workspace.selectedTab.focusedPane)
        let label = "Go to Item"
        let controller = PaletteWindowController(
            palette: Palette(sources: [source]), settings: settings, label: label,
            placeholder: "\(label) in \(source.folderNames.joined(separator: " and "))")
        present(
            controller, closedBy: WindowCommands.goToItem.id,
            switchingTo: WindowCommands.showPalette.id, over: window)
    }

    /// Shows `controller`'s palette over `window` with the keys in its field. Command `id`'s
    /// chords and Close Pane's close it, those a menu could have as key equivalents: the field
    /// types a plain one, such as "j" or Esc. Command `other`'s chords close it and show the
    /// other palette, which gives the keys back where this one would have. As it closes, the
    /// keys go back where they were; a chosen folder or row then gives them to the focused
    /// pane, where it went (docs/decisions/0087-palette-window.md).
    private func present(
        _ controller: PaletteWindowController, closedBy id: CommandID,
        switchingTo other: CommandID, over window: NSWindow
    ) {
        controller.closingChords = { [weak self] in
            self?.menuChords(of: [id, TilingCommands.closePane.id]) ?? []
        }
        controller.switchingChords = { [weak self] in self?.menuChords(of: [other]) ?? [] }
        controller.onSwitchingChord = { [weak self, weak controller] in
            // Closing gives the keys back, so the other palette finds them where this one did.
            controller?.close()
            guard let self else { return }
            if other == WindowCommands.goToItem.id {
                showItemPalette()
            } else {
                showPalette()
            }
        }
        controller.viewController.didRun = { [weak self] item in
            switch item.kind {
            case .folder, .entry: self?.giveKeysBack()
            case .workspace, .command: break
            }
        }
        // Where the keys were, to give them back there: a field's editor stands in for the field.
        var keys = window.firstResponder
        if let editor = keys as? NSTextView, editor.isFieldEditor,
            let field = editor.delegate as? NSResponder
        {
            keys = field
        }
        controller.onClose = { [weak self, weak controller, weak keys] in
            guard let self, palette === controller else { return }
            palette = nil
            giveKeys(backTo: keys)
        }
        palette = controller
        controller.show(over: window)
    }

    /// The chords of `ids` that a menu could have as key equivalents, from the focused table's
    /// registry, so they follow the user's shortcuts.
    private func menuChords(of ids: [CommandID]) -> Set<KeyChord> {
        // A closed window's workspace has no focused table to read.
        guard !isClosed, !workspace.isClosed else { return [] }
        let registry = focusedTable.registry
        return Set(ids.flatMap { registry.command(for: $0).map(MainMenuBuilder.menuChords) ?? [] })
    }

    /// Gives the keys back to `responder`, which had them when the palette opened: the focused
    /// pane's table, the sidebar or the filter field. One that has left the window or is
    /// hidden gives them to the focused pane.
    private func giveKeys(backTo responder: NSResponder?) {
        guard !isClosed, !workspace.isClosed, let window else { return }
        if let view = responder as? NSView, view.window === window,
            !view.isHiddenOrHasHiddenAncestor, window.makeFirstResponder(view)
        {
            return
        }
        giveKeysBack()
    }

    private func canRunFromPalette(_ id: CommandID) -> Bool {
        !isClosed && !workspace.isClosed && focusedTable.canRunCommand(id)
    }

    /// Runs a command the palette chose on the focused pane's table, as its key would, if it
    /// can still run once the palette has closed.
    private func runFromPalette(_ id: CommandID) {
        guard canRunFromPalette(id) else { return }
        focusedTable.run(id)
        followFocus(after: id)
    }
}
