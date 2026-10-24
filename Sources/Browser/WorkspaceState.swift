import Foundation

/// A workspace as plain values, as `WorkspaceStore` keeps it: its window's frame, its tabs in
/// strip order and the selected one, and whether the sidebar shows. A workspace with a name is a
/// saved one; one without is the workspace of an open window that hasn't been named.
public struct WorkspaceState: Codable, Equatable, Sendable {
    /// Names the workspace's file, so it stays the same across renames.
    public let id: UUID
    public let name: String?
    /// The window's frame, as Interface gives it.
    public let frame: Rect
    public let tabs: [TabState]
    /// An index into `tabs`.
    public let selectedTab: Int
    public let showsSidebar: Bool

    /// - Precondition: `tabs` isn't empty and `selectedTab` is one of its indices.
    public init(
        id: UUID, name: String?, frame: Rect, tabs: [TabState], selectedTab: Int,
        showsSidebar: Bool
    ) {
        precondition(
            tabs.indices.contains(selectedTab),
            "selected tab \(selectedTab) isn't one of the \(tabs.count) tabs")
        self.id = id
        self.name = name
        self.frame = frame
        self.tabs = tabs
        self.selectedTab = selectedTab
        self.showsSidebar = showsSidebar
    }

    /// The same state under `name`, as a rename or a free name at launch gives it.
    public func renamed(_ name: String?) -> WorkspaceState {
        WorkspaceState(
            id: id, name: name, frame: frame, tabs: tabs, selectedTab: selectedTab,
            showsSidebar: showsSidebar)
    }

    // MARK: Coding

    private enum CodingKeys: String, CodingKey {
        case id, name, frame, tabs, selectedTab, showsSidebar
    }

    private struct StoredFrame: Codable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encode(
            StoredFrame(x: frame.x, y: frame.y, width: frame.width, height: frame.height),
            forKey: .frame)
        try container.encode(tabs, forKey: .tabs)
        try container.encode(selectedTab, forKey: .selectedTab)
        try container.encode(showsSidebar, forKey: .showsSidebar)
    }

    /// Stored data with no tabs or a selected tab out of range is rejected, not repaired.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        let stored = try container.decode(StoredFrame.self, forKey: .frame)
        frame = Rect(x: stored.x, y: stored.y, width: stored.width, height: stored.height)
        tabs = try container.decode([TabState].self, forKey: .tabs)
        selectedTab = try container.decode(Int.self, forKey: .selectedTab)
        showsSidebar = try container.decode(Bool.self, forKey: .showsSidebar)
        guard tabs.indices.contains(selectedTab) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription:
                        "selected tab \(selectedTab) isn't one of the \(tabs.count) tabs"))
        }
    }
}
