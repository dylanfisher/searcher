import Foundation

/// The windows open when the app last saved, as `WorkspaceStore` keeps them: each one's
/// workspace, in window order, and the key window's.
public struct SessionState: Codable, Equatable, Sendable {
    /// `WorkspaceState.id`s, front window first.
    public let workspaces: [UUID]
    /// One of `workspaces`, or nil when no window was key.
    public let keyWindow: UUID?

    /// - Precondition: `workspaces` has no ID twice, and `keyWindow` is nil or one of them.
    public init(workspaces: [UUID], keyWindow: UUID?) {
        if let problem = Self.problem(workspaces: workspaces, keyWindow: keyWindow) {
            preconditionFailure(problem)
        }
        self.workspaces = workspaces
        self.keyWindow = keyWindow
    }

    private enum CodingKeys: String, CodingKey {
        case workspaces, keyWindow
    }

    /// Stored data that breaks the precondition is rejected, not repaired.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspaces = try container.decode([UUID].self, forKey: .workspaces)
        keyWindow = try container.decodeIfPresent(UUID.self, forKey: .keyWindow)
        if let problem = Self.problem(workspaces: workspaces, keyWindow: keyWindow) {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: problem))
        }
    }

    private static func problem(workspaces: [UUID], keyWindow: UUID?) -> String? {
        if Set(workspaces).count != workspaces.count {
            return "the session lists a workspace twice: \(workspaces)"
        }
        if let keyWindow, !workspaces.contains(keyWindow) {
            return "the key window's workspace \(keyWindow) isn't among the session's \(workspaces)"
        }
        return nil
    }
}
