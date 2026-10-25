import Darwin
import Testing

@testable import Bench

/// The block is mapped with mmap, not malloc. malloc keeps a freed large block resident and
/// serves the next large request from it, so when another test in this process has just freed
/// one, touching a malloc'd block adds nothing to the footprint, and neither does any retry
/// (measured: 64, 0, 0 MB on three malloc rounds, 64, 64, 64 on three mmap rounds). Fresh
/// pages are never resident. Another test freeing memory between the two readings can still hide
/// some of the growth, so a reading that misses it is taken again.
@Test func footprintGrowsWithTouchedMemory() throws {
    let size = 64 << 20
    // A freed, still resident malloc block: what the other tests leave behind.
    let leftover = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
    leftover.initializeMemory(as: UInt8.self, repeating: 1, count: size)
    leftover.deallocate()

    let attempts = 5
    for _ in 0..<attempts {
        let before = try Footprint.current()
        let block = try #require(
            mmap(nil, size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0))
        try #require(block != MAP_FAILED, "mmap failed: errno \(errno)")
        defer { munmap(block, size) }
        block.initializeMemory(as: UInt8.self, repeating: 1, count: size)
        let after = try Footprint.current()
        if after >= before + UInt64(size) / 2 { return }
    }
    Issue.record("the footprint grew by less than half of \(size) bytes in \(attempts) attempts")
}
