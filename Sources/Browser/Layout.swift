/// The panes of one tab: a binary split tree with the focused pane, focus history and zoom. It
/// computes every pane frame and divider rect for a given container, so focus by direction and
/// "other pane" need no window. Edits that set sizes take the container's bounds and keep every
/// pane at least `minimumPaneSize` on both sides.
public struct Layout: Codable, Equatable, Sendable {
    /// No edit makes a pane narrower or shorter than this, in points.
    public static let minimumPaneSize = 120.0
    /// The space between two siblings, in points. Interface draws the divider in it.
    public static let dividerThickness = 1.0

    public private(set) var root: LayoutNode
    public private(set) var focused: PaneID
    /// Every pane, most recently focused first, so `history[0]` is `focused`.
    public private(set) var history: [PaneID]
    /// The focused pane fills the container and no dividers show. Any edit that changes the focused
    /// pane or a size ends it.
    public private(set) var isZoomed: Bool

    public init(pane: PaneID = PaneID()) {
        root = .pane(pane)
        focused = pane
        history = [pane]
        isZoomed = false
    }

    /// Stored data that breaks an invariant is rejected, not repaired.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        root = try container.decode(LayoutNode.self, forKey: .root)
        focused = try container.decode(PaneID.self, forKey: .focused)
        history = try container.decode([PaneID].self, forKey: .history)
        isZoomed = try container.decode(Bool.self, forKey: .isZoomed)
        if let problem = invariantViolation {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: problem))
        }
    }

    public var panes: [PaneID] { root.panes }

    // MARK: Editing

    /// Splits the focused pane in half along `axis`. The new pane goes right of or below it and
    /// takes focus. Returns `nil` and changes nothing when a half would be under the minimum size.
    @discardableResult
    public mutating func split(_ axis: Axis, in bounds: Rect) -> PaneID? {
        guard
            let frame = Self.frames(of: root, in: bounds, gap: Self.dividerThickness)[focused],
            frame.extent(along: axis) >= 2 * Self.minimumPaneSize + Self.dividerThickness
        else { return nil }
        let new = PaneID()
        root = Self.replacing(focused, in: root) {
            .split(axis: axis, ratio: 0.5, first: $0, second: .pane(new))
        }
        focus(new)
        return new
    }

    /// Closes the focused pane and focuses the one focused before it. Returns the closed pane, or
    /// `nil` when it's the last one, so the caller closes the tab instead.
    @discardableResult
    public mutating func close() -> PaneID? {
        guard let rest = Self.removing(focused, from: root) else { return nil }
        let closed = focused
        root = rest
        history.removeFirst()
        focused = history[0]
        isZoomed = false
        return closed
    }

    public mutating func focus(_ pane: PaneID) {
        precondition(panes.contains(pane), "\(pane) is not in the layout")
        guard pane != focused else { return }
        focused = pane
        history.removeAll { $0 == pane }
        history.insert(pane, at: 0)
        isZoomed = false
    }

    /// Focuses the neighbor in `direction`, if there is one.
    public mutating func focus(_ direction: Direction) {
        if let neighbor = neighbor(of: focused, direction) {
            focus(neighbor)
        }
    }

    /// Swaps the focused pane with its neighbor in `direction`. Focus stays on the moved pane.
    public mutating func move(_ direction: Direction) {
        guard let neighbor = neighbor(of: focused, direction) else { return }
        let moved = focused
        root = Self.swapping(moved, neighbor, in: root)
        isZoomed = false
    }

    /// Moves a divider on the focused pane's edge `points` toward `direction`, stopping where a
    /// pane would go under the minimum size. The divider is the one on the pane's right edge, or
    /// bottom edge for ↑ and ↓, and the one on its left or top edge only when it has none there,
    /// so the tree's shape never changes which divider moves.
    public mutating func resize(_ direction: Direction, by points: Double, in bounds: Rect) {
        let axis = direction.axis
        guard
            let path = Self.path(toSplitOn: axis, holding: focused, in: .first, of: root)
                ?? Self.path(toSplitOn: axis, holding: focused, in: .second, of: root)
        else { return }
        let signed = direction == .left || direction == .up ? -points : points
        changeRatio(at: path, in: bounds) { ratio, space in ratio + signed / space }
    }

    /// Sets the ratio of the split at `path`, as a divider drag does, clamped so that no pane goes
    /// under the minimum size.
    public mutating func setRatio(_ ratio: Double, at path: [LayoutNode.Child], in bounds: Rect) {
        changeRatio(at: path, in: bounds) { _, _ in ratio }
    }

    /// Gives every pane in a run of same-axis splits an equal share, as far as the minimum size
    /// allows.
    public mutating func equalize(in bounds: Rect) {
        root = Self.equalized(root, in: bounds)
        isZoomed = false
    }

    public mutating func toggleZoom() {
        isZoomed.toggle()
    }

    // MARK: Geometry

    /// Each pane's frame in `bounds`. When `bounds` is smaller than the tree needs, panes can be
    /// under the minimum size; edits never shrink them further.
    public func frames(in bounds: Rect) -> [PaneID: Rect] {
        if isZoomed { return [focused: bounds] }
        return Self.frames(of: root, in: bounds, gap: Self.dividerThickness)
    }

    /// A divider between the two children of a split.
    public struct Divider: Equatable, Sendable {
        /// The children to follow from the root to reach the split.
        public let path: [LayoutNode.Child]
        public let axis: Axis
        public let rect: Rect
        /// The whole split's rect.
        public let span: Rect

        /// The ratio that puts the divider's leading edge at `position`, an x for a horizontal
        /// split and a y for a vertical one.
        public func ratio(at position: Double) -> Double {
            let start = axis == .horizontal ? span.minX : span.minY
            return (position - start) / (span.extent(along: axis) - Layout.dividerThickness)
        }
    }

    /// Every divider in `bounds`, outermost first. None while zoomed.
    public func dividers(in bounds: Rect) -> [Divider] {
        if isZoomed { return [] }
        var dividers: [Divider] = []
        func walk(_ node: LayoutNode, _ rect: Rect, _ path: [LayoutNode.Child]) {
            guard case .split(let axis, let ratio, let first, let second) = node else { return }
            let parts = rect.divided(along: axis, ratio: ratio, divider: Self.dividerThickness)
            dividers.append(Divider(path: path, axis: axis, rect: parts.divider, span: rect))
            walk(first, parts.first, path + [.first])
            walk(second, parts.second, path + [.second])
        }
        walk(root, bounds, [])
        return dividers
    }

    /// The pane across the nearest edge of `pane` in `direction`. It must share some of that edge;
    /// among equally near panes the most recently focused wins, then the one sharing the most.
    /// Ignores zoom, since the tree under it keeps its shape.
    public func neighbor(of pane: PaneID, _ direction: Direction) -> PaneID? {
        // Ratios alone fix which panes touch, so a unit square without dividers is enough.
        let frames = Self.frames(of: root, in: Rect(x: 0, y: 0, width: 1, height: 1), gap: 0)
        guard let from = frames[pane] else { return nil }
        let tolerance = 1e-9
        var best: (pane: PaneID, distance: Double, recency: Int, overlap: Double)?
        for (other, frame) in frames where other != pane {
            let distance: Double
            let overlap: Double
            switch direction {
            case .left:
                distance = from.minX - frame.maxX
                overlap = min(from.maxY, frame.maxY) - max(from.minY, frame.minY)
            case .right:
                distance = frame.minX - from.maxX
                overlap = min(from.maxY, frame.maxY) - max(from.minY, frame.minY)
            case .up:
                distance = from.minY - frame.maxY
                overlap = min(from.maxX, frame.maxX) - max(from.minX, frame.minX)
            case .down:
                distance = frame.minY - from.maxY
                overlap = min(from.maxX, frame.maxX) - max(from.minX, frame.minX)
            }
            guard distance >= -tolerance, overlap > tolerance else { continue }
            let recency = history.firstIndex(of: other) ?? history.count
            if let current = best {
                let nearer = distance < current.distance - tolerance
                let tied = abs(distance - current.distance) <= tolerance
                guard nearer || (tied && (recency, -overlap) < (current.recency, -current.overlap))
                else { continue }
            }
            best = (other, distance, recency, overlap)
        }
        return best?.pane
    }

    // MARK: Invariants

    private var invariantViolation: String? {
        let panes = panes
        if Set(panes).count != panes.count { return "a pane appears twice in the tree" }
        if history.first != focused { return "history doesn't start with the focused pane" }
        if history.count != panes.count || Set(history) != Set(panes) {
            return "history doesn't list every pane once"
        }
        if !Self.ratiosAreValid(root) { return "a split ratio is outside 0 to 1" }
        return nil
    }

    private static func ratiosAreValid(_ node: LayoutNode) -> Bool {
        guard case .split(_, let ratio, let first, let second) = node else { return true }
        return ratio > 0 && ratio < 1 && ratiosAreValid(first) && ratiosAreValid(second)
    }

    // MARK: Sizes

    /// Replaces the ratio of the split at `path` with `change(ratio, space)`, where `space` is
    /// the split's extent less the divider, clamped to the minimum size. Splits inside it are then
    /// refitted, since moving a divider toward a nested split squeezes that split's panes.
    private mutating func changeRatio(
        at path: [LayoutNode.Child], in bounds: Rect,
        _ change: (_ ratio: Double, _ space: Double) -> Double
    ) {
        func walk(_ node: LayoutNode, _ rect: Rect, _ path: ArraySlice<LayoutNode.Child>)
            -> LayoutNode
        {
            guard case .split(let axis, let ratio, let first, let second) = node else {
                preconditionFailure("the path leads past a pane")
            }
            guard let next = path.first else {
                let space = rect.extent(along: axis) - Self.dividerThickness
                let wanted = change(ratio, space)
                let clamped = Self.clamped(wanted, axis, first, second, in: rect) ?? ratio
                return Self.fitted(
                    .split(axis: axis, ratio: clamped, first: first, second: second), in: rect)
            }
            let parts = rect.divided(along: axis, ratio: ratio, divider: Self.dividerThickness)
            return switch next {
            case .first:
                .split(
                    axis: axis, ratio: ratio, first: walk(first, parts.first, path.dropFirst()),
                    second: second)
            case .second:
                .split(
                    axis: axis, ratio: ratio, first: first,
                    second: walk(second, parts.second, path.dropFirst()))
            }
        }
        root = walk(root, bounds, path[...])
        isZoomed = false
    }

    /// The smallest extent along `axis` that fits the subtree when its own ratios may change.
    private static func minimumExtent(of node: LayoutNode, along axis: Axis) -> Double {
        switch node {
        case .pane:
            return minimumPaneSize
        case .split(let splitAxis, _, let first, let second):
            let a = minimumExtent(of: first, along: axis)
            let b = minimumExtent(of: second, along: axis)
            return splitAxis == axis ? a + dividerThickness + b : max(a, b)
        }
    }

    /// `ratio` limited so that both children fit at their minimum extent in `rect`, or `nil` when
    /// `rect` is too small for both.
    private static func clamped(
        _ ratio: Double, _ axis: Axis, _ first: LayoutNode, _ second: LayoutNode, in rect: Rect
    ) -> Double? {
        let space = rect.extent(along: axis) - dividerThickness
        let lower = minimumExtent(of: first, along: axis) / space
        let upper = 1 - minimumExtent(of: second, along: axis) / space
        // A child sized to its exact minimum can come back a rounding error short of it.
        guard lower <= upper + 1e-9 else { return nil }
        return min(upper, max(lower, ratio))
    }

    /// Clamps every ratio, outermost first, so that each child gets at least its minimum extent.
    /// A split whose rect is too small for both children keeps its ratio.
    private static func fitted(_ node: LayoutNode, in rect: Rect) -> LayoutNode {
        guard case .split(let axis, let ratio, let first, let second) = node else { return node }
        let fit = clamped(ratio, axis, first, second, in: rect) ?? ratio
        let parts = rect.divided(along: axis, ratio: fit, divider: dividerThickness)
        return .split(
            axis: axis, ratio: fit, first: fitted(first, in: parts.first),
            second: fitted(second, in: parts.second))
    }

    /// Panes in a run of same-axis splits count as siblings, as in i3.
    private static func weight(of node: LayoutNode, along axis: Axis) -> Int {
        guard case .split(let splitAxis, _, let first, let second) = node, splitAxis == axis else {
            return 1
        }
        return weight(of: first, along: axis) + weight(of: second, along: axis)
    }

    /// Ratios that give every pane in a run of same-axis splits the same extent, dividers counted,
    /// clamped as `fitted` clamps them.
    private static func equalized(_ node: LayoutNode, in rect: Rect) -> LayoutNode {
        guard case .split(let axis, let ratio, let first, let second) = node else { return node }
        let a = Double(weight(of: first, along: axis))
        let b = Double(weight(of: second, along: axis))
        let extent = rect.extent(along: axis)
        let share = (extent - (a + b - 1) * dividerThickness) / (a + b)
        let equal = (a * share + (a - 1) * dividerThickness) / (extent - dividerThickness)
        let fit = clamped(equal, axis, first, second, in: rect) ?? ratio
        let parts = rect.divided(along: axis, ratio: fit, divider: dividerThickness)
        return .split(
            axis: axis, ratio: fit, first: equalized(first, in: parts.first),
            second: equalized(second, in: parts.second))
    }

    // MARK: Tree

    private static func frames(of node: LayoutNode, in rect: Rect, gap: Double) -> [PaneID: Rect] {
        var frames: [PaneID: Rect] = [:]
        func walk(_ node: LayoutNode, _ rect: Rect) {
            switch node {
            case .pane(let id):
                frames[id] = rect
            case .split(let axis, let ratio, let first, let second):
                let parts = rect.divided(along: axis, ratio: ratio, divider: gap)
                walk(first, parts.first)
                walk(second, parts.second)
            }
        }
        walk(node, rect)
        return frames
    }

    /// The path to the innermost split on `axis` that holds `pane` in its `side` child: with
    /// `.first`, the split whose divider is on the pane's right or bottom edge.
    private static func path(
        toSplitOn axis: Axis, holding pane: PaneID, in side: LayoutNode.Child, of node: LayoutNode
    ) -> [LayoutNode.Child]? {
        guard case .split(let splitAxis, _, let first, let second) = node else { return nil }
        let (child, subtree): (LayoutNode.Child, LayoutNode) =
            first.panes.contains(pane) ? (.first, first) : (.second, second)
        if let inner = path(toSplitOn: axis, holding: pane, in: side, of: subtree) {
            return [child] + inner
        }
        return splitAxis == axis && child == side && subtree.panes.contains(pane) ? [] : nil
    }

    private static func replacing(
        _ pane: PaneID, in node: LayoutNode, with make: (LayoutNode) -> LayoutNode
    ) -> LayoutNode {
        switch node {
        case .pane(let id):
            id == pane ? make(node) : node
        case .split(let axis, let ratio, let first, let second):
            .split(
                axis: axis, ratio: ratio, first: replacing(pane, in: first, with: make),
                second: replacing(pane, in: second, with: make))
        }
    }

    /// The tree without `pane`, its sibling taking the parent's place. `nil` when `pane` is the
    /// whole tree.
    private static func removing(_ pane: PaneID, from node: LayoutNode) -> LayoutNode? {
        switch node {
        case .pane(let id):
            return id == pane ? nil : node
        case .split(let axis, let ratio, let first, let second):
            guard let keptFirst = removing(pane, from: first) else { return second }
            guard let keptSecond = removing(pane, from: second) else { return first }
            return .split(axis: axis, ratio: ratio, first: keptFirst, second: keptSecond)
        }
    }

    private static func swapping(_ a: PaneID, _ b: PaneID, in node: LayoutNode) -> LayoutNode {
        switch node {
        case .pane(let id):
            id == a ? .pane(b) : id == b ? .pane(a) : node
        case .split(let axis, let ratio, let first, let second):
            .split(
                axis: axis, ratio: ratio, first: swapping(a, b, in: first),
                second: swapping(a, b, in: second))
        }
    }
}

extension Rect {
    fileprivate func extent(along axis: Axis) -> Double {
        axis == .horizontal ? width : height
    }

    /// The two children's rects and the divider between them. `ratio` is the first child's share
    /// of the extent left after the divider.
    fileprivate func divided(along axis: Axis, ratio: Double, divider: Double) -> (
        first: Rect, divider: Rect, second: Rect
    ) {
        switch axis {
        case .horizontal:
            let w = (width - divider) * ratio
            return (
                Rect(x: x, y: y, width: w, height: height),
                Rect(x: x + w, y: y, width: divider, height: height),
                Rect(x: x + w + divider, y: y, width: width - w - divider, height: height)
            )
        case .vertical:
            let h = (height - divider) * ratio
            return (
                Rect(x: x, y: y, width: width, height: h),
                Rect(x: x, y: y + h, width: width, height: divider),
                Rect(x: x, y: y + h + divider, width: width, height: height - h - divider)
            )
        }
    }
}
