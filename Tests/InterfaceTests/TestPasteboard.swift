import AppKit

/// A pasteboard no other test uses, so tests that run at once don't read each other's items.
func testPasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("searcher-test-\(UUID().uuidString)"))
}
