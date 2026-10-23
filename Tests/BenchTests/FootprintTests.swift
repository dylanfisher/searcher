import Testing

@testable import Bench

/// The test process runs other tests at once, and one that frees memory between the two
/// readings, or memory pressure that makes the kernel give back pages, can hide the growth. So
/// a reading that misses the growth is taken again; every attempt missing means the footprint
/// doesn't follow touched memory.
@Test func footprintGrowsWithTouchedMemory() throws {
    let size = 64 << 20
    let attempts = 5
    for _ in 0..<attempts {
        let before = try Footprint.current()
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 1, count: size)
        let after = try Footprint.current()
        if after >= before + UInt64(size) / 2 { return }
    }
    Issue.record("the footprint grew by less than half of \(size) bytes in \(attempts) attempts")
}
