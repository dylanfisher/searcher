import Foundation

/// The raw samples of the UI bench, in milliseconds, as `.build/bench-ui.json` holds them. The app
/// writes one launch's samples; the bench runner appends every launch's and writes the whole set.
/// Each span is timed from its start to the Core Animation commit of the frame that shows it.
public struct UIBenchRecord: Sendable, Codable, Equatable {
    /// Process start → first window frame (B1), one per launch.
    public var launch: [Double]
    /// Open W1 → frame with its first rows (B2.W1).
    public var openW1: [Double]
    /// Open W2 → frame with its first rows (B2.W2).
    public var openW2: [Double]
    /// ↓ key event timestamp → frame with the moved selection, on W2 (B6).
    public var keyDown: [Double]
    /// Opt-↓ and Opt-↑ alternating, each key event timestamp → frame with the moved selection, on
    /// W2 (B6). This and the next three are the row commands other than ↓, timed in the launch
    /// that times ↓.
    public var optionArrows: [Double]
    /// Ctrl-Shift-↓ key → frame, on W2 (B6).
    public var controlShiftDown: [Double]
    /// Fn-↓ (Page Down) key → frame, on W2 (B6).
    public var pageDown: [Double]
    /// Shift-↓ key → frame with the extended selection, on W2 (B6).
    public var shiftDown: [Double]
    /// Cmd-A key → frame with every row selected, on W2 (B6).
    public var selectAll: [Double]
    /// A folder change patch landing with every row selected → frame with the patched rows, on W2
    /// (B6).
    public var patchAllSelected: [Double]
    /// A reload's complete listing landing with every row selected: start of the main thread's
    /// pass that takes it in → frame with its rows, on W2 (B6).
    public var reloadAllSelected: [Double]
    /// A patch that adds an entry above most rows landing with every row selected → frame with
    /// the shifted rows, on W2 (B6).
    public var patchAddingAllSelected: [Double]
    /// The selection change of a click selecting half the rows → frame, on W2 (B6).
    public var clickHalf: [Double]
    /// A patch landing after Shift-↓ changed a half-row selection while it ran: start of the main
    /// thread's pass that takes it in → frame, on W2 (B6).
    public var patchAfterShiftDown: [Double]
    /// A reload's complete listing landing after Cmd-A on its first batch: start of the main
    /// thread's pass that takes it in → frame, on W2 (B6).
    public var loadAfterSelectAll: [Double]
    /// A type-to-select key → frame with the first matching row selected, on W2 sorted by name
    /// (B6).
    public var typeSelect: [Double]
    /// Sort column change → frame with the re-sorted rows, on W2 (B8).
    public var sortChange: [Double]
    /// Cmd-Shift-. key → frame with hidden files shown or hidden, on W2 (B8). Two per launch:
    /// shown, then hidden again.
    public var hiddenToggle: [Double]
    /// Folders First turned on or off → frame with the rearranged rows, on W2 (B8). Two per
    /// launch: on, then off.
    public var foldersFirstToggle: [Double]
    /// A sort key (Ctrl-Opt-Cmd-6, then Ctrl-Opt-Cmd-1) → frame with the re-sorted rows, on W2
    /// (B8). Two per launch.
    public var sortKey: [Double]
    /// A key typed in the filter field, or Esc clearing it → frame with the rows filtered by the
    /// new text, on W2 (B7). Six per launch: five characters, then Esc.
    public var filterKey: [Double]
    /// ↓ key → frame in W2's first column, sorted with Folders First, each ↓ moving onto a folder
    /// and opening its column (B6).
    public var columnDown: [Double]
    /// → key → frame, from W2's first column into the selected folder's (B6).
    public var columnRight: [Double]
    /// ← key → frame, back to W2's first column (B6).
    public var columnLeft: [Double]
    /// ↓ key → frame in the focused pane of a two-pane split, both panes on W2 (B6).
    public var splitDown: [Double]
    /// ↓ key → frame in the focused pane of a 4-pane grid, every pane on W2 (B6).
    public var gridDown: [Double]
    /// Ten panes of one window opening W2 at once, the focused pane's load asked last → frame
    /// with the focused pane's first rows (B2.W2). The span ends at the first commit after which
    /// the whole window has nothing to draw, so the other panes' drawing can fall inside it: the
    /// longest a user could wait, not the focused pane's draw alone.
    public var tenPaneOpen: [Double]
    /// `cold` scenario: open a never-opened subfolder of `--path` → frame with its first rows
    /// (B3).
    public var coldOpen: [Double]
    /// `revisit` scenario: open a subfolder of `--path` listed before → frame with its cached
    /// rows (B4).
    public var revisit: [Double]
    /// `column-walk` scenario: each arrow key walking `--path` in column view → frame (B6).
    public var columnWalkKey: [Double]
    /// ↓ key → frame on W2, with the operations panel open, while the queue copies W8 to a disk
    /// image (B6). Only presses whose frame came before the copy finished.
    public var queueKeyDown: [Double]
    /// Every run loop pass over the stall threshold (B10), all launches together.
    public var stalls: [Stall]

    /// One stall and the span its run loop pass belongs to (`TimedSpan.name(coveringPassFrom:)`).
    public struct Stall: Sendable, Codable, Equatable {
        public let milliseconds: Double
        /// A span's name, or `UIBenchRecord.betweenSpans`.
        public let span: String

        public init(milliseconds: Double, span: String) {
            self.milliseconds = milliseconds
            self.span = span
        }
    }

    /// The span name of a stall reported while no span was running.
    public static let betweenSpans = "between spans"
    /// The span name of the launch, B1's span, which starts at the process start.
    public static let launchSpan: StaticString = "launch"
    /// The span name of the rest of the launch: from the first window's frame until the window
    /// is visible and the launch warm-up has ended. Nothing in it is timed.
    public static let warmUpSpan = "launch warm-up"
    /// The spans of the launch, before the first span after it.
    public static var launchSpans: Set<String> { ["\(launchSpan)", warmUpSpan] }
    /// The span name of ten panes opening W2, up to the focused pane's first rows frame.
    public static let tenPaneOpenSpan: StaticString = "ten-pane open"
    /// The span name of the rest of the ten panes' load: from the focused pane's first rows frame
    /// until every pane holds its complete listing. Nothing in it is timed.
    public static let tenPaneRestSpan = "ten-pane load"
    /// The spans of the ten-pane load, whose stalls the report counts on their own.
    public static var tenPaneSpans: Set<String> { ["\(tenPaneOpenSpan)", tenPaneRestSpan] }
    /// The span name of a ↓ press while the queue copies W8.
    public static let queueKeySpan: StaticString = "key down while copying"
    /// The span name of the rest of the W8 copy, from the call that queues it until the main
    /// thread learns it finished, outside its ↓ presses.
    public static let queueCopySpan: StaticString = "W8 copy"
    /// The spans of the W8 copy, whose stalls are judged against B10.
    public static var queueCopySpans: Set<String> { ["\(queueKeySpan)", "\(queueCopySpan)"] }

    public init(
        launch: [Double] = [], openW1: [Double] = [], openW2: [Double] = [],
        keyDown: [Double] = [], optionArrows: [Double] = [], controlShiftDown: [Double] = [],
        pageDown: [Double] = [], shiftDown: [Double] = [], selectAll: [Double] = [],
        patchAllSelected: [Double] = [], reloadAllSelected: [Double] = [],
        patchAddingAllSelected: [Double] = [], clickHalf: [Double] = [],
        patchAfterShiftDown: [Double] = [], loadAfterSelectAll: [Double] = [],
        typeSelect: [Double] = [], sortChange: [Double] = [], hiddenToggle: [Double] = [],
        foldersFirstToggle: [Double] = [], sortKey: [Double] = [], filterKey: [Double] = [],
        columnDown: [Double] = [], columnRight: [Double] = [], columnLeft: [Double] = [],
        splitDown: [Double] = [], gridDown: [Double] = [], tenPaneOpen: [Double] = [],
        coldOpen: [Double] = [], revisit: [Double] = [], columnWalkKey: [Double] = [],
        queueKeyDown: [Double] = [], stalls: [Stall] = []
    ) {
        self.launch = launch
        self.openW1 = openW1
        self.openW2 = openW2
        self.keyDown = keyDown
        self.optionArrows = optionArrows
        self.controlShiftDown = controlShiftDown
        self.pageDown = pageDown
        self.shiftDown = shiftDown
        self.selectAll = selectAll
        self.patchAllSelected = patchAllSelected
        self.reloadAllSelected = reloadAllSelected
        self.patchAddingAllSelected = patchAddingAllSelected
        self.clickHalf = clickHalf
        self.patchAfterShiftDown = patchAfterShiftDown
        self.loadAfterSelectAll = loadAfterSelectAll
        self.typeSelect = typeSelect
        self.sortChange = sortChange
        self.hiddenToggle = hiddenToggle
        self.foldersFirstToggle = foldersFirstToggle
        self.sortKey = sortKey
        self.filterKey = filterKey
        self.columnDown = columnDown
        self.columnRight = columnRight
        self.columnLeft = columnLeft
        self.splitDown = splitDown
        self.gridDown = gridDown
        self.tenPaneOpen = tenPaneOpen
        self.coldOpen = coldOpen
        self.revisit = revisit
        self.columnWalkKey = columnWalkKey
        self.queueKeyDown = queueKeyDown
        self.stalls = stalls
    }

    /// Adds `other`'s samples after these.
    public mutating func append(_ other: UIBenchRecord) {
        launch += other.launch
        openW1 += other.openW1
        openW2 += other.openW2
        keyDown += other.keyDown
        optionArrows += other.optionArrows
        controlShiftDown += other.controlShiftDown
        pageDown += other.pageDown
        shiftDown += other.shiftDown
        selectAll += other.selectAll
        patchAllSelected += other.patchAllSelected
        reloadAllSelected += other.reloadAllSelected
        patchAddingAllSelected += other.patchAddingAllSelected
        clickHalf += other.clickHalf
        patchAfterShiftDown += other.patchAfterShiftDown
        loadAfterSelectAll += other.loadAfterSelectAll
        typeSelect += other.typeSelect
        sortChange += other.sortChange
        hiddenToggle += other.hiddenToggle
        foldersFirstToggle += other.foldersFirstToggle
        sortKey += other.sortKey
        filterKey += other.filterKey
        columnDown += other.columnDown
        columnRight += other.columnRight
        columnLeft += other.columnLeft
        splitDown += other.splitDown
        gridDown += other.gridDown
        tenPaneOpen += other.tenPaneOpen
        coldOpen += other.coldOpen
        revisit += other.revisit
        columnWalkKey += other.columnWalkKey
        queueKeyDown += other.queueKeyDown
        stalls += other.stalls
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> UIBenchRecord {
        try JSONDecoder().decode(UIBenchRecord.self, from: data)
    }
}
