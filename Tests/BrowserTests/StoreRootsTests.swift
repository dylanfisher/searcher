import Foundation
import Testing

@testable import Browser

@Test func noBundleIDFailsWithAMessage() {
    #expect {
        _ = try StoreRoots.user(bundleID: nil)
    } throws: { error in
        "\(error)".contains("bundle ID")
    }
}

@Test func userRootsAreNamedByTheBundleID() throws {
    let roots = try StoreRoots.user(bundleID: "com.example.searcher")
    #expect(roots.caches.path.hasSuffix("/Library/Caches/com.example.searcher"))
    #expect(
        roots.applicationSupport.path.hasSuffix(
            "/Library/Application Support/com.example.searcher"))
}

@Test func injectedRootsAreUsedAsGiven() {
    let caches = URL(fileURLWithPath: "/tmp/a")
    let support = URL(fileURLWithPath: "/tmp/b")
    let roots = StoreRoots(caches: caches, applicationSupport: support)
    #expect(roots.caches == caches)
    #expect(roots.applicationSupport == support)
}
