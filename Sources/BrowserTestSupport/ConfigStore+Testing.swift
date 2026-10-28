import Browser
import Foundation
import TestSupport

/// A config store's watch that reports a change only when the test says so, in place of
/// FSEvents.
public final class ManualWatch: Sendable {
    private let changes = EventLog<@Sendable () -> Void>()
    /// The folders watched, in the order the watches started.
    public let folders = EventLog<String>()
    /// One entry for each watch stopped.
    public let stops = EventLog<Void>()

    public init() {}

    public var watch: ConfigStore.Watch {
        { folder, onChange in
            self.folders.append(folder)
            self.changes.append(onChange)
            return { self.stops.append(()) }
        }
    }

    /// Reports a change in each watched folder, as an event batch from FSEvents does.
    public func change() {
        for onChange in changes.all { onChange() }
    }
}

/// `text` as a config file reads it.
public func configLoad(_ text: String) -> ConfigLoad {
    ConfigFile.parse(Data(text.utf8))
}

extension Settings {
    /// Connects the config file at `file` as the app does, with no menu rules for its
    /// shortcuts, `watch` in place of FSEvents and `clock` timing the writes and the second
    /// reads. A file a test
    /// later moves the settings to is made the same way. The default location is `file`.
    /// `write` replaces `AtomicWrite`, for a test of a write that fails.
    public func connectTestConfig(
        _ file: URL, clock: ManualClock = ManualClock(), watch: ManualWatch = ManualWatch(),
        reserved: Set<KeyChord> = [], fixed: [KeyChord: CommandID] = [:],
        log: @escaping @Sendable (String) -> Void = { _ in },
        write: ConfigStore.Write? = nil
    ) async {
        await connectConfig(defaultFile: file, clock: clock) { file, isDefault in
            if let write {
                ConfigStore(
                    file: file, createsFolder: isDefault, reserved: reserved, fixed: fixed,
                    log: log, watch: watch.watch, clock: clock, write: write)
            } else {
                ConfigStore(
                    file: file, createsFolder: isDefault, reserved: reserved, fixed: fixed,
                    log: log, watch: watch.watch, clock: clock)
            }
        }
    }
}

/// Settings connected to a config file in a folder of their own, and a way to save the file as
/// an editor does, for a test of what a save of the file changes.
@MainActor
public final class ConfigFixture {
    public let folder: TemporaryFolder
    /// The config file, `config.json` in `folder`.
    public let file: URL
    public let watch = ManualWatch()
    public let clock = ManualClock()
    public let settings: Settings

    /// A fixture named for the test file `name`, whose config file starts with `text`, or with
    /// none, which the connection writes from the defaults.
    public init(_ name: String, text: String? = nil) async throws {
        folder = try TemporaryFolder(name)
        file = folder.url.appending(path: ConfigFile.name)
        if let text { try Data(text.utf8).write(to: file) }
        settings = Settings(
            defaults: temporarySuite(in: folder.url.path), log: unexpectedSettingsLog)
        await settings.connectTestConfig(file, clock: clock, watch: watch)
    }

    /// Writes `text` over the file as an editor's atomic save does, and reports the change.
    public func save(_ text: String) throws {
        try Data(text.utf8).write(to: file, options: .atomic)
        watch.change()
    }
}
