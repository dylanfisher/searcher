import Foundation

/// The stable name of a tab in a workspace. A UUID, as `PaneID` is, so tabs made in different
/// windows never collide.
public struct TabID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init() {
        rawValue = UUID()
    }

    public var description: String { rawValue.uuidString }
}
