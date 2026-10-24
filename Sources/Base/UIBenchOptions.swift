/// What the bench runner asks of one UI bench launch of the app, and the only spelling of the
/// arguments that carry it: the runner builds them with `arguments` and the app reads them back.
public struct UIBenchOptions: Sendable, Equatable {
    public static let flag = "--bench-ui"

    /// A run of one part of the UI bench, named by `--scenario`, instead of the CI run.
    public enum Scenario: String, CaseIterable, Sendable {
        /// W2 in column view: ↓ through folder rows, each opening a column, then → and ← (B6).
        case columnKeys = "column-keys"
        /// 20 never-opened subfolders of `--path`, each opened once (B3 cold).
        case cold
        /// The same subfolders opened again, showing their cached rows (B4).
        case revisit
        /// `--path` in column view walked with the arrow keys, counting stalls (B6, B10).
        case columnWalk = "column-walk"
        /// W2 in a split window: ↓ in the focused pane of two panes and of a 4-pane grid (B6),
        /// and ten panes opening W2 at once to the focused pane's first rows (B2).
        case splits
        /// A cold launch restoring a saved session of 3 windows × 2 tabs × 4 panes on W1, one
        /// pane on W2, to every window on screen and the key window's focused pane showing
        /// rows (B1).
        case restoredSession = "restored-session"

        /// Whether it times a real folder, `--path`, which it never defaults to.
        public var needsPath: Bool {
            self != .columnKeys && self != .splits && self != .restoredSession
        }
    }

    /// Times the `splits` scenario's one launch opens W2 in ten panes, for as many samples as the
    /// CI run's launches give, one each.
    public static let tenPaneOpens = 20

    /// Where the app writes its `UIBenchRecord`.
    public let output: String
    /// The folders opened as W1 and W2. A scenario that times `--path` gets it as both.
    public let w1: String
    public let w2: String
    /// Synthetic ↓ presses on W2; zero for a launch that times everything else.
    public let keyPresses: Int
    /// The app's `TempRoot` prefix, chosen by the runner so it can remove what a launch it had to
    /// kill left behind.
    public let tempPrefix: String
    /// Nil for the CI run.
    public let scenario: Scenario?
    /// The subfolders `cold` and `revisit` open, chosen by the runner; empty otherwise.
    public let folders: [String]
    /// The W8 folder the CI run's launch that presses keys copies, and the mount point of the
    /// disk image it copies to; nil in every other launch.
    public let w8: String?
    public let image: String?

    public init(
        output: String, w1: String, w2: String, keyPresses: Int, tempPrefix: String,
        scenario: Scenario?, folders: [String], w8: String? = nil, image: String? = nil
    ) {
        self.output = output
        self.w1 = w1
        self.w2 = w2
        self.keyPresses = keyPresses
        self.tempPrefix = tempPrefix
        self.scenario = scenario
        self.folders = folders
        self.w8 = w8
        self.image = image
    }

    /// The spelling of a nil `scenario`, `w8` or `image`.
    private static let none = "-"

    /// The options in `arguments`, or nil when `flag` isn't there. Traps on a malformed set: only
    /// the runner writes them.
    public init?(arguments: [String]) {
        guard let start = arguments.firstIndex(of: Self.flag) else { return nil }
        let rest = arguments[arguments.index(after: start)...]
        let values = Array(rest.prefix(9))
        guard values.count == 9, let keyPresses = Int(values[3]), keyPresses >= 0,
            values[5] == Self.none || Scenario(rawValue: values[5]) != nil,
            let folderCount = Int(values[8]), folderCount >= 0,
            rest.count >= 9 + folderCount
        else {
            preconditionFailure(
                "\(Self.flag) needs <output> <w1> <w2> <key presses> <temp prefix> <scenario> "
                    + "<w8> <image> <folder count> <folders…>, got \(Array(rest))")
        }
        self.init(
            output: values[0], w1: values[1], w2: values[2], keyPresses: keyPresses,
            tempPrefix: values[4], scenario: Scenario(rawValue: values[5]),
            folders: Array(rest.dropFirst(9).prefix(folderCount)),
            w8: values[6] == Self.none ? nil : values[6],
            image: values[7] == Self.none ? nil : values[7])
    }

    public var arguments: [String] {
        [
            Self.flag, output, w1, w2, String(keyPresses), tempPrefix,
            scenario?.rawValue ?? Self.none, w8 ?? Self.none, image ?? Self.none,
            String(folders.count),
        ] + folders
    }
}
