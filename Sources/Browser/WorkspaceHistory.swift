/// A window's Back and Forward past its panes' own: what the window showed before a saved
/// workspace was opened into it, and what it showed when Back left it. A pane steps through its
/// own `History` first; Back in a pane with none left steps the window
/// (docs/decisions/0125-workspace-open-is-a-back-step.md).
public struct WorkspaceHistory: Codable, Equatable, Sendable {
    /// The steps kept each way. Each holds every tab of the window with its panes' own Back and
    /// Forward, up to `History.limit` entries each way per pane, so a step can run to hundreds of
    /// kilobytes, and the window file holds them all. A step needs the window to drift from its
    /// saved workspace and the workspace opened again, which few runs repeat ten times.
    public static let limit = 10

    /// What a window shows, as `WorkspaceState` keeps it, without its frame: Back and Forward
    /// never move the window.
    public struct Step: Codable, Equatable, Sendable {
        public let tabs: [TabState]
        /// An index into `tabs`.
        public let selectedTab: Int
        public let showsSidebar: Bool

        /// - Precondition: `tabs` isn't empty and `selectedTab` is one of its indices.
        public init(tabs: [TabState], selectedTab: Int, showsSidebar: Bool) {
            precondition(
                tabs.indices.contains(selectedTab),
                "selected tab \(selectedTab) isn't one of the \(tabs.count) tabs")
            self.tabs = tabs
            self.selectedTab = selectedTab
            self.showsSidebar = showsSidebar
        }

        /// The same step with each pane's history passed through `transform`.
        func withHistories(_ transform: (History) -> History) -> Step {
            Step(
                tabs: tabs.map { $0.withHistories(transform) }, selectedTab: selectedTab,
                showsSidebar: showsSidebar)
        }

        private enum CodingKeys: String, CodingKey {
            case tabs, selectedTab, showsSidebar
        }

        /// Stored data with no tabs or a selected tab out of range is rejected, not repaired.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
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

    /// Nearest last.
    public private(set) var back: [Step] = []
    /// Nearest last.
    public private(set) var forward: [Step] = []

    public init() {}

    /// A history with these steps, nearest last; past `limit`, the farthest go.
    public init(back: [Step], forward: [Step]) {
        self.back = Array(back.suffix(Self.limit))
        self.forward = Array(forward.suffix(Self.limit))
    }

    public var isEmpty: Bool { back.isEmpty && forward.isEmpty }

    /// Records `step` as left for a workspace opened in its place, which ends the way forward.
    mutating func leave(_ step: Step) {
        Self.add(step, to: &back)
        forward.removeAll()
    }

    /// The step before `current`, which becomes the way forward; nil at the start.
    mutating func back(from current: Step) -> Step? {
        guard let step = back.popLast() else { return nil }
        Self.add(current, to: &forward)
        return step
    }

    /// The step `back` last stepped from, with `current` the way back again; nil at the end.
    mutating func forward(from current: Step) -> Step? {
        guard let step = forward.popLast() else { return nil }
        Self.add(current, to: &back)
        return step
    }

    /// Ends the way forward, as a pane's navigation does.
    mutating func dropForward() {
        forward.removeAll()
    }

    /// Adds `step` nearest in `steps`, dropping the farthest past `limit`.
    private static func add(_ step: Step, to steps: inout [Step]) {
        steps.append(step)
        if steps.count > limit { steps.removeFirst() }
    }
}
