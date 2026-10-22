import Base
import Darwin
import Testing

@Test func mountWithoutLocalFlagIsNetwork() {
    #expect(VolumeKind(mountFlags: UInt32(MNT_LOCAL) | UInt32(MNT_RDONLY)) == .local)
    #expect(VolumeKind(mountFlags: UInt32(MNT_RDONLY)) == .network)
}
