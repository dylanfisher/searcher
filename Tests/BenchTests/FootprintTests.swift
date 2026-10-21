import Testing

@testable import Bench

@Test func footprintGrowsWithTouchedMemory() throws {
    let before = try Footprint.current()
    let size = 64 << 20
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
    defer { buffer.deallocate() }
    buffer.initializeMemory(as: UInt8.self, repeating: 1, count: size)
    let after = try Footprint.current()
    #expect(after >= before + UInt64(size) / 2)
}
