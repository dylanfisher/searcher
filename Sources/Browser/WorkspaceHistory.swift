/// A window's Back and Forward past its panes' own: what the window showed before a saved
/// workspace was opened into it, and what it showed when Back left it. A pane steps through its
/// own `History` first; Back in a pane with none left steps the window
/// (docs/decisions/0125-workspace-open-is-a-back-step.md).
public struct WorkspaceHistory: Codable, Equatable, Sendable {
    /// The steps kept each way. A step needs the window to drift from its saved workspace and
    /// the workspace opened again, which few runs repeat ten times.
    public static let limit = 10
    /// The Back and Forward entries each pane of a step keeps each way, the nearest. Every save
    /// writes the window file whole and every launch reads it, so a step can't carry the 500 a
    /// live pane keeps (`History.limit`): with one, 10 steps each way of 8 tabs of 4 panes add
    /// 477 KB to the window file (docs/decisions/0125-workspace-open-is-a-back-step.md).
    public static let paneEntries = 1

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

        /// The same step with each pane's Back and Forward cut to their nearest `paneEntries`.
        var bounded: Step {
            withHistories {
                History(
                    back: Array($0.backEntries.suffix(paneEntries)),
                    forward: Array($0.forwardEntries.suffix(paneEntries)))
            }
        }

        /// Whether a pane keeps more than `paneEntries` either way.
        var isOverBound: Bool {
            tabs.contains { tab in
                tab.panes.values.contains {
                    $0.history.backEntries.count > paneEntries
                        || $0.history.forwardEntries.count > paneEntries
                }
            }
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

    /// A history with these steps, nearest last; past `limit`, the farthest go, and each pane
    /// keeps its nearest `paneEntries` each way.
    public init(back: [Step], forward: [Step]) {
        self.back = back.suffix(Self.limit).map(\.bounded)
        self.forward = forward.suffix(Self.limit).map(\.bounded)
    }

    private enum CodingKeys: String, CodingKey {
        case back, forward
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(back, forKey: .back)
        try container.encode(forward, forKey: .forward)
    }

    /// Stored steps past `limit` either way, or a pane of one past `paneEntries`, are rejected,
    /// not trimmed: only a file edited by hand or of another build holds them.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        back = try container.decode([Step].self, forKey: .back)
        forward = try container.decode([Step].self, forKey: .forward)
        func broken(_ reason: String) -> DecodingError {
            .dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: reason))
        }
        guard back.count <= Self.limit, forward.count <= Self.limit else {
            throw broken(
                "\(back.count) steps back and \(forward.count) forward; at most \(Self.limit) each")
        }
        guard !(back + forward).contains(where: \.isOverBound) else {
            throw broken("a step's pane keeps more than \(Self.paneEntries) entries one way")
        }
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

    /// Adds `step`, bounded, nearest in `steps`, dropping the farthest past `limit`.
    private static func add(_ step: Step, to steps: inout [Step]) {
        steps.append(step.bounded)
        if steps.count > limit { steps.removeFirst() }
    }
}
