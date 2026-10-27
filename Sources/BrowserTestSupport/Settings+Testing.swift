import Browser
import Foundation
import TestSupport

/// Settings for a test that never changes one, over a `temporarySuite` under the temporary
/// directory, which removes its file with the settings.
@MainActor
public func untouchedSettings() -> Settings {
    Settings(defaults: temporarySuite(in: FileManager.default.temporaryDirectory.path))
}

/// `untouchedSettings` with folder sizes on, for a test of the walks that setting starts.
@MainActor
public func sizedSettings() -> Settings {
    let settings = untouchedSettings()
    settings.folderSizes = true
    return settings
}

/// Settings stored in `folder`, which takes the suite's file with it when the test removes it.
@MainActor
public func storedSettings(in folder: TemporaryFolder) -> Settings {
    Settings(defaults: temporarySuite(in: folder.url.path))
}
