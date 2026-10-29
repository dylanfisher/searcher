import Base
import Foundation
import Testing

/// The startup volume reports a capacity.
@Test func theStartupVolumeHasACapacity() async throws {
    let capacity = try await BlockingCallThread.run {
        try availableCapacity(atPath: NSTemporaryDirectory())
    }
    #expect(try #require(capacity) > 0)
}

/// A path that isn't there is an error, not a capacity of nothing.
@Test func aMissingPathThrows() async {
    await #expect(throws: (any Error).self) {
        try await BlockingCallThread.run {
            try availableCapacity(atPath: "/no/such/folder/for/AvailableCapacityTests")
        }
    }
}
