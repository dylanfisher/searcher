import Foundation

/// The stable name of a pane in a layout. A UUID, so panes made in different windows never collide
/// and a saved layout needs no counter stored beside it.
public struct PaneID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init() {
        rawValue = UUID()
    }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue.uuidString }
}
