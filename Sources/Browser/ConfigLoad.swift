/// What one read of the config file found, for `Settings.applyConfig(_:)`.
public struct ConfigLoad: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        /// There is no file: every preference reads as its default.
        case missing
        /// The values the file sets, every line of it good.
        case values([Settings.Key: Settings.Value])
        /// What is wrong with the file, which sets nothing.
        case failed([ConfigError])
    }

    let outcome: Outcome

    /// No file.
    public static let missing = ConfigLoad(outcome: .missing)

    /// A file with `errors`, which sets nothing.
    public static func failed(_ errors: [ConfigError]) -> ConfigLoad {
        precondition(!errors.isEmpty, "a failed config load with no errors")
        return ConfigLoad(outcome: .failed(errors))
    }

    /// What is wrong with the file; empty when it applies, or there is none.
    public var errors: [ConfigError] {
        guard case .failed(let errors) = outcome else { return [] }
        return errors
    }

    /// The values the file sets; empty when it has an error, or there is none.
    var values: [Settings.Key: Settings.Value] {
        guard case .values(let values) = outcome else { return [:] }
        return values
    }
}
