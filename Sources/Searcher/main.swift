import AppKit
import Browser
import Interface

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windows: [BrowserWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = BrowserWindowController(location: Location(path: NSHomeDirectory()))
        windows.append(controller)
        controller.showWindow(nil)
        NSApp.activate()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
