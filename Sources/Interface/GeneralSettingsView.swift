import AppKit
import Browser
import Observation
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// What the General pane shows and does: Open at login, which the system's login items hold. The
/// checkbox shows the status last read from them, never a stored copy, and is read again when
/// the window shows and when the app becomes active, so a change made in System Settings shows
/// (docs/decisions/0113-open-at-login.md).
///
/// Under it, whether other apps' Show in Finder opens Searcher, which the global `NSFileViewer`
/// key holds, read the same way (docs/decisions/0137-default-file-viewer.md).
///
/// Under that, the config file, which holds the settings: where it is, and buttons that choose
/// another place for it, open it in an editor, show it in Finder and put it back at the default
/// place (docs/decisions/0123-config-is-the-settings.md), and one that copies a new file's text,
/// every setting at its default (docs/decisions/0130-copy-default-config.md).
@MainActor @Observable
final class GeneralSettings {
    /// What the pane says while the item waits for the user to allow it in System Settings.
    static let approvalNote =
        "Searcher opens at login once you allow it in System Settings ▸ General ▸ Login Items."
    /// What the pane says when the running app can't be a login item.
    static let unavailableNote =
        "Open at login is available only when Searcher runs from its app bundle."

    @ObservationIgnored private let loginItem: any LoginItem
    private(set) var loginItemStatus: SMAppService.Status
    /// Why the last change to Open at login failed, until OK dismisses it.
    private(set) var loginItemProblem: String?
    /// Posts an accessibility notification. Tests replace it to record what would be posted.
    @ObservationIgnored var postAccessibility:
        @MainActor (
            Any, NSAccessibility.Notification, [NSAccessibility.NotificationUserInfoKey: Any]?
        )
            -> Void = { element, notification, userInfo in
                NSAccessibility.post(
                    element: element, notification: notification, userInfo: userInfo)
            }

    @ObservationIgnored private let settings: Browser.Settings
    @ObservationIgnored private let systemActions: any SystemActions
    /// Asks the user for a place to keep the config file: a file, or a folder to keep
    /// `ConfigFile.name` in; nil when they cancel. Tests replace it so no panel shows.
    @ObservationIgnored var chooseConfigLocation: @MainActor () async -> URL? = {
        await GeneralSettings.runConfigLocationPanel()
    }
    /// The config file's path, as `Settings.configFile` last had it; nil for settings with
    /// none, which hide its section.
    private(set) var configFilePath: String?
    /// Whether the config file is at the default place, which turns Use Default off.
    private(set) var configFileIsDefault: Bool
    /// The move to another place running, which tests wait for.
    @ObservationIgnored private(set) var move: Task<Void, Never>?
    /// The check that the file is there before Reveal in Finder, which tests wait for.
    @ObservationIgnored private(set) var reveal: Task<Void, Never>?
    /// Why the last Reveal in Finder showed nothing, until OK dismisses it.
    private(set) var configProblem: String?
    /// Whether Copy Default Config's button says `copiedTitle`, as it does for `copiedDuration`
    /// after a copy.
    private(set) var defaultConfigCopied = false
    /// Times how long the button says `copiedTitle`. Tests replace it.
    @ObservationIgnored var clock: any Clock<Duration> = ContinuousClock()
    /// The wait that turns the button's title back, which tests wait for.
    @ObservationIgnored private(set) var copiedReset: Task<Void, Never>?

    @ObservationIgnored private let fileViewer: any FileViewerSetting
    /// The bundle ID the global `NSFileViewer` key named when last read; nil when it wasn't set.
    private(set) var fileViewerID: String?
    /// What the pane says under the file viewer checkbox, as of the last read.
    private(set) var fileViewerNote: String?
    /// Why the last change to the file viewer failed, until OK dismisses it.
    private(set) var fileViewerProblem: String?

    init(
        loginItem: any LoginItem, fileViewer: any FileViewerSetting, settings: Browser.Settings,
        systemActions: any SystemActions
    ) {
        self.loginItem = loginItem
        loginItemStatus = loginItem.status
        self.fileViewer = fileViewer
        (fileViewerID, fileViewerNote) = Self.read(fileViewer)
        self.settings = settings
        self.systemActions = systemActions
        configFilePath = settings.configFile?.path
        configFileIsDefault = settings.configFileIsDefault
        settings.observe(for: self) { [weak self, weak settings] in
            guard let self, let settings else { return }
            let path = settings.configFile?.path
            if path != configFilePath { configFilePath = path }
            if settings.configFileIsDefault != configFileIsDefault {
                configFileIsDefault = settings.configFileIsDefault
            }
        }
    }

    /// What the pane says under the config file's path.
    static let configNote =
        "Searcher keeps its settings in this file, and applies the file each time it's saved."

    func openConfigFile() {
        SystemCommands.openConfig(settings: settings, systemActions: systemActions)
    }

    /// Shows the config file in Finder. A file that isn't there, as on a volume that isn't
    /// connected, says so under the buttons instead, since Finder would show nothing.
    func revealConfigFile() {
        guard let file = settings.configFile else { return }
        reveal = Task {
            defer { reveal = nil }
            let isThere = await Task.detached { ConfigStore.fileIsThere(file) }.value
            if isThere {
                configProblem = nil
                systemActions.revealInFinder([file])
                return
            }
            let problem = Self.missingNote(file)
            configProblem = problem
            postAccessibility(
                NSApp as Any, .announcementRequested,
                [
                    .announcement: problem,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ])
        }
    }

    /// A button under the config file's path, in the order the pane shows them. Each is a
    /// bordered push button, which AppKit draws in its hover, pressed, focused and disabled
    /// states (docs/decisions/0110-interaction-states.md).
    enum ConfigButton: CaseIterable, Identifiable {
        case change, openInEditor, revealInFinder, useDefault, copyDefault

        var id: Self { self }

        /// Every title the button can have, the usual one first.
        var titles: [String] {
            switch self {
            case .change: ["Change…"]
            case .openInEditor: ["Open in Editor"]
            case .revealInFinder: [SystemCommands.revealInFinder.title]
            case .useDefault: ["Use Default"]
            case .copyDefault:
                [SystemCommands.copyDefaultConfig.title, GeneralSettings.copiedTitle]
            }
        }
    }

    /// What `button` says now.
    func title(of button: ConfigButton) -> String {
        button == .copyDefault && defaultConfigCopied ? Self.copiedTitle : button.titles[0]
    }

    /// Whether `button` is on: Use Default is off at the default place.
    func isEnabled(_ button: ConfigButton) -> Bool {
        button != .useDefault || !configFileIsDefault
    }

    func press(_ button: ConfigButton) {
        switch button {
        case .change: changeConfigLocation()
        case .openInEditor: openConfigFile()
        case .revealInFinder: revealConfigFile()
        case .useDefault: useDefaultConfigLocation()
        case .copyDefault: copyDefaultConfig()
        }
    }

    /// What Copy Default Config's button says for a moment after a copy, as a Copy button in
    /// macOS does.
    nonisolated static let copiedTitle = "Copied"
    static let copiedDuration: Duration = .milliseconds(1500)

    /// Puts a new config file's text, every setting at its default, on the pasteboard, and has
    /// the button say `copiedTitle` for `copiedDuration`; a copy meanwhile starts it again.
    func copyDefaultConfig() {
        SystemCommands.copyDefault(systemActions: systemActions)
        defaultConfigCopied = true
        postAccessibility(
            NSApp as Any, .announcementRequested,
            [
                .announcement: Self.copiedTitle,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ])
        copiedReset?.cancel()
        copiedReset = Task { [clock] in
            try? await clock.sleep(for: Self.copiedDuration)
            guard !Task.isCancelled else { return }
            defaultConfigCopied = false
            copiedReset = nil
        }
    }

    /// What the pane says when the config file isn't there to show in Finder.
    static func missingNote(_ file: URL) -> String {
        "There's no file at \((file.path as NSString).abbreviatingWithTildeInPath) to show in"
            + " Finder."
    }

    func dismissConfigProblem() {
        configProblem = nil
    }

    /// Asks for another place for the config file and moves the settings there: a file there
    /// is read, and with none the settings are written there.
    func changeConfigLocation() {
        guard move == nil else { return }
        move = Task {
            defer { move = nil }
            guard let chosen = await chooseConfigLocation() else { return }
            await settings.moveConfig(to: chosen)
        }
    }

    func useDefaultConfigLocation() {
        guard move == nil else { return }
        move = Task {
            defer { move = nil }
            await settings.useDefaultConfigFile()
        }
    }

    /// The open panel for Change…: a JSON file, or a folder, which can be made from it.
    private static func runConfigLocationPanel() async -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose Config File Location"
        panel.message = "Choose a config file, or a folder for one."
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        let response = await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0) }
        }
        return response == .OK ? panel.url : nil
    }

    /// Whether the checkbox is on: registered, or registered and waiting for approval.
    var opensAtLogin: Bool { loginItemStatus == .enabled || needsApproval }

    var needsApproval: Bool { loginItemStatus == .requiresApproval }

    var canChangeOpensAtLogin: Bool { loginItem.isAvailable }

    /// What the pane says under the checkbox, if anything.
    var loginItemNote: String? {
        if !loginItem.isAvailable { return Self.unavailableNote }
        return needsApproval ? Self.approvalNote : nil
    }

    /// Reads the status from the system again.
    func refreshLoginItem() {
        loginItemStatus = loginItem.status
    }

    /// Adds Searcher to the login items or removes it, then reads the status back, which shows
    /// what the system did whether or not the change went through.
    func setOpensAtLogin(_ opens: Bool) {
        defer { refreshLoginItem() }
        do {
            if opens {
                try loginItem.register()
            } else {
                try loginItem.unregister()
            }
            loginItemProblem = nil
        } catch {
            let change = opens ? "added to" : "removed from"
            let problem =
                "Searcher couldn't be \(change) the login items: \(error.localizedDescription)"
            loginItemProblem = problem
            postAccessibility(
                NSApp as Any, .announcementRequested,
                [
                    .announcement: problem,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ])
        }
    }

    func dismissLoginItemProblem() {
        loginItemProblem = nil
    }

    func openLoginItemsSettings() {
        loginItem.openSystemSettings()
    }

    // MARK: File viewer

    static let fileViewerTitle = "Use Searcher instead of Finder to show files"
    /// What the pane says under the file viewer checkbox, always.
    static let fileViewerDescription =
        "Other apps' Show in Finder opens Searcher. Finder itself, the Dock and some apps still"
        + " use Finder."
    /// What the pane says when the running app can't be the file viewer.
    static let fileViewerUnavailableNote =
        "Searcher can show other apps' files only when it runs from its app bundle."

    /// Whether the checkbox is on: the global key names Searcher.
    var showsFilesInSearcher: Bool {
        fileViewer.searcherID.map { $0 == fileViewerID } ?? false
    }

    var canChangeFileViewer: Bool { fileViewer.searcherID != nil }

    /// Whether Use Default is on: the key names any app.
    var canUseDefaultFileViewer: Bool { fileViewerID != nil }

    /// Reads the global key again.
    func refreshFileViewer() {
        (fileViewerID, fileViewerNote) = Self.read(fileViewer)
    }

    /// Writes Searcher's ID to the global key, or removes it if it still names Searcher, then
    /// reads the key back, which shows what was saved whether or not the change went through.
    func setShowsFilesInSearcher(_ shows: Bool) {
        guard let searcherID = fileViewer.searcherID else {
            preconditionFailure("the file viewer checkbox changed while it was disabled")
        }
        if shows {
            changeFileViewer(to: searcherID)
        } else if fileViewer.viewer == searcherID {
            changeFileViewer(to: nil)
        } else {
            refreshFileViewer()
        }
    }

    /// Removes the global key whatever it names, which hands other apps' reveals back to Finder.
    func useDefaultFileViewer() {
        changeFileViewer(to: nil)
    }

    func dismissFileViewerProblem() {
        fileViewerProblem = nil
    }

    private func changeFileViewer(to id: String?) {
        defer { refreshFileViewer() }
        do {
            try fileViewer.setViewer(id)
            fileViewerProblem = nil
        } catch {
            let problem = "The file viewer couldn't be changed: \(error.localizedDescription)"
            fileViewerProblem = problem
            postAccessibility(
                NSApp as Any, .announcementRequested,
                [
                    .announcement: problem,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ])
        }
    }

    /// The ID `fileViewer`'s key names, and the note under the checkbox for it: why it can't
    /// change outside the app bundle, or which other app the key names, if any.
    private static func read(_ fileViewer: any FileViewerSetting) -> (String?, String?) {
        let id = fileViewer.viewer
        guard fileViewer.searcherID != nil else { return (id, fileViewerUnavailableNote) }
        guard let id, id != fileViewer.searcherID else { return (id, nil) }
        guard let name = fileViewer.appName(of: id) else {
            return (
                id,
                "Other apps' Show in Finder names \u{201C}\(id)\u{201D}, which isn't installed,"
                    + " so Finder shows files."
            )
        }
        return (id, "Other apps' Show in Finder opens \(name).")
    }
}

/// The General pane of the Settings window.
struct GeneralSettingsView: View {
    /// The room between the pane's edges and what it shows.
    static let padding: CGFloat = 20

    @Bindable var model: GeneralSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(
                "Open at login",
                isOn: Binding(
                    get: { model.opensAtLogin }, set: { model.setOpensAtLogin($0) })
            )
            .toggleStyle(.checkbox)
            .disabled(!model.canChangeOpensAtLogin)
            if let note = model.loginItemNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            if model.needsApproval {
                Button("Open Login Items Settings") { model.openLoginItemsSettings() }
                    .controlSize(.small)
            }
            if let problem = model.loginItemProblem {
                HStack {
                    Text(problem).font(.caption).foregroundStyle(Color.red)
                    Spacer()
                    Button("OK") { model.dismissLoginItemProblem() }.controlSize(.small)
                }
            }
            fileViewer.padding(.top, 8)
            if let path = model.configFilePath {
                Divider().padding(.vertical, 8)
                configFile(path)
            }
            Spacer()
        }
        .padding(Self.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The file viewer checkbox, with Use Default beside it, and its notes. The checkbox and the
    /// bordered push button get their hover, pressed, focused and disabled states from AppKit
    /// (docs/decisions/0110-interaction-states.md).
    private var fileViewer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle(
                    GeneralSettings.fileViewerTitle,
                    isOn: Binding(
                        get: { model.showsFilesInSearcher },
                        set: { model.setShowsFilesInSearcher($0) })
                )
                .toggleStyle(.checkbox)
                .disabled(!model.canChangeFileViewer)
                Button("Use Default") { model.useDefaultFileViewer() }
                    .disabled(!model.canUseDefaultFileViewer)
            }
            Text(GeneralSettings.fileViewerDescription).font(.caption)
                .foregroundStyle(.secondary)
            if let note = model.fileViewerNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            if let problem = model.fileViewerProblem {
                HStack {
                    Text(problem).font(.caption).foregroundStyle(Color.red)
                    Spacer()
                    Button("OK") { model.dismissFileViewerProblem() }.controlSize(.small)
                }
            }
        }
    }

    /// Where the config file is, and its buttons.
    @ViewBuilder
    private func configFile(_ path: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Config file")
            Text((path as NSString).abbreviatingWithTildeInPath)
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text(GeneralSettings.configNote).font(.caption).foregroundStyle(.secondary)
        }
        ConfigFileButtons(model: model).padding(.top, 4)
        if let problem = model.configProblem {
            HStack {
                Text(problem).font(.caption).foregroundStyle(Color.red)
                Spacer()
                Button("OK") { model.dismissConfigProblem() }.controlSize(.small)
            }
        }
    }
}

/// The config file's buttons in a row, as `GeneralSettings.ConfigButton` lists them. A button
/// whose title changes takes the room of its widest title, so the row doesn't move.
struct ConfigFileButtons: View {
    let model: GeneralSettings

    var body: some View {
        HStack {
            ForEach(GeneralSettings.ConfigButton.allCases) { button in
                let title = model.title(of: button)
                Button {
                    model.press(button)
                } label: {
                    ZStack {
                        ForEach(button.titles, id: \.self) { Text($0).opacity($0 == title ? 1 : 0) }
                    }
                }
                .disabled(!model.isEnabled(button))
                .accessibilityLabel(title)
            }
        }
    }
}
