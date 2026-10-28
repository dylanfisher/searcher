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
/// Under it, the config file, which holds the settings: where it is, and buttons that choose
/// another place for it, open it in an editor, show it in Finder and put it back at the default
/// place (docs/decisions/0123-config-is-the-settings.md).
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

    init(loginItem: any LoginItem, settings: Browser.Settings, systemActions: any SystemActions) {
        self.loginItem = loginItem
        loginItemStatus = loginItem.status
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

    func revealConfigFile() {
        guard let file = settings.configFile else { return }
        systemActions.revealInFinder([file])
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
        panel.message =
            "Choose a config file, or a folder to keep \(ConfigFile.name) in. Searcher reads a"
            + " file that's there, and saves its settings to a place with none."
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
}

/// The General pane of the Settings window.
struct GeneralSettingsView: View {
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
            if let path = model.configFilePath {
                Divider().padding(.vertical, 8)
                configFile(path)
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Where the config file is, and its buttons. Each is a bordered push button, which AppKit
    /// draws in its hover, pressed, focused and disabled states
    /// (docs/decisions/0110-interaction-states.md).
    @ViewBuilder
    private func configFile(_ path: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Config file")
            Text((path as NSString).abbreviatingWithTildeInPath)
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text(GeneralSettings.configNote).font(.caption).foregroundStyle(.secondary)
        }
        HStack {
            Button("Change…") { model.changeConfigLocation() }
            Button("Open in Editor") { model.openConfigFile() }
            Button(SystemCommands.revealInFinder.title) { model.revealConfigFile() }
            Button("Use Default") { model.useDefaultConfigLocation() }
                .disabled(model.configFileIsDefault)
        }
        .padding(.top, 4)
    }
}
