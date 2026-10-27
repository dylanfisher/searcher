import Foundation

/// Handing the pane's entries to the rest of the system: Copy Path writes the selection's paths to
/// the pasteboard, one per line, Reveal in Finder shows the selection in Finder, Get Info opens
/// Finder's Info window for each selected entry, and Open Terminal Here opens the pane's folder in
/// the app `Settings.terminalBundleID` names. With nothing selected, Copy Path, Reveal in Finder
/// and Get Info act on the pane's folder. At a server, which has no folder, they act only on
/// the selected shares, and Open Terminal Here is off (docs/decisions/0114-server-location.md).
public enum SystemCommands: CommandSet {
    public static let copyPath = Command(
        id: CommandID("system.copyPath"), title: "Copy Path",
        chords: [KeyChord("c", modifiers: [.option, .command])])
    public static let revealInFinder = Command(
        id: CommandID("system.revealInFinder"), title: "Reveal in Finder",
        chords: [KeyChord("r", modifiers: [.option, .command])])
    public static let getInfo = Command(
        id: CommandID("system.getInfo"), title: "Get Info",
        chords: [KeyChord("i", modifiers: [.command])])
    public static let openTerminal = Command(
        id: CommandID("system.openTerminal"), title: "Open Terminal Here",
        chords: [KeyChord("t", modifiers: [.option, .command])])

    // A key runs its command whether or not it is enabled, so each one checks again and does
    // nothing when it is off.
    public static var bindings: [CommandBinding] {
        [
            CommandBinding(
                copyPath, isEnabled: { hasItems(in: $0.pane) },
                run: { context in
                    guard let urls = items(in: context.pane) else { return }
                    let paths = urls.map(\.path)
                    context.pane.systemActions.copyToPasteboard(paths.joined(separator: "\n"))
                }),
            CommandBinding(
                revealInFinder, isEnabled: { hasItems(in: $0.pane) },
                run: { context in
                    guard let urls = items(in: context.pane) else { return }
                    context.pane.systemActions.revealInFinder(urls)
                }),
            CommandBinding(
                getInfo, isEnabled: { hasItems(in: $0.pane) },
                run: { context in
                    guard let urls = items(in: context.pane) else { return }
                    context.pane.systemActions.showInfo(urls)
                }),
            CommandBinding(
                openTerminal, isEnabled: { $0.pane.location.isFolder },
                run: { context in
                    let pane = context.pane
                    guard pane.location.isFolder else { return }
                    pane.systemActions.open(
                        folderURL(of: pane), inAppWithBundleID: pane.settings.terminalBundleID)
                }),
        ]
    }

    /// Whether Copy Path, Reveal in Finder and Get Info have something to act on: the pane's
    /// folder, or at a server, which has no folder, selected shares each mounted where its row
    /// says (0114-server-location.md, 0115-server-shares.md). A folder's rows always have
    /// their URLs, so they aren't built to tell.
    @MainActor
    private static func hasItems(in pane: Pane) -> Bool {
        pane.location.isFolder || items(in: pane) != nil
    }

    /// The selected entries' URLs in display order, or the folder's when nothing is selected or
    /// the folder has no rows yet. Nil at a server with nothing selected, and when a selected
    /// row has no location (`ClipboardCommands.selectedURLs`), so the command acts on none of
    /// it. Built from the names, with no file-system call.
    @MainActor
    private static func items(in pane: Pane) -> [URL]? {
        guard let urls = ClipboardCommands.selectedURLs(in: pane) else { return nil }
        guard urls.isEmpty else { return urls }
        return pane.location.isFolder ? [folderURL(of: pane)] : nil
    }

    @MainActor
    private static func folderURL(of pane: Pane) -> URL {
        URL(fileURLWithPath: pane.location.folderPath, isDirectory: true)
    }
}
