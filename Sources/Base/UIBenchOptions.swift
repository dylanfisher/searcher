/// What the bench runner asks of one UI bench launch of the app, and the only spelling of the
/// arguments that carry it: the runner builds them with `arguments` and the app reads them back.
public struct UIBenchOptions: Sendable, Equatable {
    public static let flag = "--bench-ui"

    /// Where the app writes its `UIBenchRecord`.
    public let output: String
    /// The folders opened as W1 and W2.
    public let w1: String
    public let w2: String
    /// Synthetic ↓ presses on W2; zero for a launch that times everything else.
    public let keyPresses: Int
    /// The app's `TempRoot` prefix, chosen by the runner so it can remove what a launch it had to
    /// kill left behind.
    public let tempPrefix: String

    public init(output: String, w1: String, w2: String, keyPresses: Int, tempPrefix: String) {
        self.output = output
        self.w1 = w1
        self.w2 = w2
        self.keyPresses = keyPresses
        self.tempPrefix = tempPrefix
    }

    /// The options in `arguments`, or nil when `flag` isn't there. Traps on a malformed set: only
    /// the runner writes them.
    public init?(arguments: [String]) {
        guard let start = arguments.firstIndex(of: Self.flag) else { return nil }
        let values = Array(arguments[arguments.index(after: start)...].prefix(5))
        guard values.count == 5, let keyPresses = Int(values[3]), keyPresses >= 0 else {
            preconditionFailure(
                "\(Self.flag) needs <output> <w1> <w2> <key presses> <temp prefix>, got \(values)")
        }
        self.init(
            output: values[0], w1: values[1], w2: values[2], keyPresses: keyPresses,
            tempPrefix: values[4])
    }

    public var arguments: [String] {
        [Self.flag, output, w1, w2, String(keyPresses), tempPrefix]
    }
}
