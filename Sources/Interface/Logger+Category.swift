import Foundation
import os

extension Logger {
    /// A logger under the app's bundle ID, the subsystem Console and `log stream` filter on. A test
    /// process has another bundle ID, or none, and logs under its process name.
    public init(category: String) {
        self.init(
            subsystem: Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName,
            category: category)
    }
}
