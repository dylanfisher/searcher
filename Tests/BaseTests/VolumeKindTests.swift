import Darwin
import Testing

@testable import Base

@Test func rootIsLocal() throws {
    #expect(try VolumeKind(path: "/") == .local)
}

@Test func mountWithoutLocalFlagIsNetwork() {
    #expect(VolumeKind(mountFlags: UInt32(MNT_LOCAL) | UInt32(MNT_RDONLY)) == .local)
    #expect(VolumeKind(mountFlags: UInt32(MNT_RDONLY)) == .network)
}

@Test func missingPathThrowsNotFound() {
    #expect(throws: ListingError(path: "/no/such/folder", code: ENOENT)) {
        try VolumeKind(path: "/no/such/folder")
    }
}
