import Foundation
import TestSupport
import Testing

@testable import Bench

@Test func shortFreeSpaceFailsBeforeAnyWriteNamingNeededAndFreeBytes() throws {
    let folder = try TemporaryFolder("DiskImagePlanTests")
    let root = folder.url.appending(path: "fixtures")
    let plan = try #require(
        DiskImagePlan(for: .ui(app: "/b/Searcher.app", folder: nil, scenario: nil), root: root))
    #expect(plan.sourceBytes == Fixture(.w8, root: root).bytes)
    #expect(plan.imageBytes > Fixture(.w8, root: root).bytes)
    #expect {
        try plan.check(free: 1_000, in: folder.url.path)
    } throws: { error in
        let text = String(describing: error)
        return text.contains("\(plan.sourceBytes) bytes")
            && text.contains("\(plan.imageBytes) bytes")
            && text.contains("\(plan.sourceBytes + plan.imageBytes) bytes")
            && text.contains("1000 bytes are free")
    }
    // Planning and checking wrote nothing.
    #expect(!FileManager.default.fileExists(atPath: root.path))
}

@Test func enoughFreeSpacePasses() throws {
    let plan = try #require(DiskImagePlan(for: .run(folder: nil), root: URL(filePath: "/nowhere")))
    try plan.check(free: plan.sourceBytes + plan.imageBytes, in: "/nowhere")
}

@Test func harnessRunCopiesTheOneGigabyteSource() throws {
    let plan = try #require(DiskImagePlan(for: .run(folder: nil), root: URL(filePath: "/nowhere")))
    #expect(plan.source.workload == .copySource)
    #expect(plan.sourceBytes == 1_000_000_000)
}

@Test func theCIVariantNeedsASmallerImage() throws {
    let root = URL(filePath: "/nowhere")
    let full = try #require(
        DiskImagePlan(for: .ui(app: "/a", folder: nil, scenario: nil), root: root))
    let ci = try #require(
        DiskImagePlan(for: .ui(app: "/a", folder: nil, scenario: nil, w8: .w8CI), root: root))
    #expect(ci.source.workload == .w8CI)
    #expect(ci.imageBytes < full.imageBytes)
    #expect(Int64(ci.imageMegabytes) * 1_000_000 >= ci.imageBytes)
}

@Test func runsThatCopyNothingNeedNoImage() {
    let root = URL(filePath: "/nowhere")
    #expect(DiskImagePlan(for: .checkIdle, root: root) == nil)
    #expect(DiskImagePlan(for: .help, root: root) == nil)
    #expect(DiskImagePlan(for: .ui(app: "/a", folder: "/nas", scenario: .cold), root: root) == nil)
}

@Test func aBuiltSourceNeedsNoMoreSpace() throws {
    let folder = try TemporaryFolder("DiskImagePlanTests")
    let source = Fixture(
        .copySource, seed: Fixture.seed, root: folder.url,
        entries: [Fixture.Entry(path: "small", size: 10, modified: 0)])
    try source.prepare()
    let plan = DiskImagePlan(source: source)
    #expect(plan.sourceBytes == 0)
    #expect(plan.imageBytes > 10)
}
