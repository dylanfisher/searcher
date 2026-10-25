/// A value the test promises is only used where it is safe, to carry it into a `@Sendable`
/// closure. For a type whose `Sendable` status depends on how the compiler was run: an internal
/// `@MainActor` class seen through `@testable import` is `Sendable` when its test file is built
/// in a batch and not when the file is built alone, so neither a plain capture nor
/// `nonisolated(unsafe)` builds in both (docs/decisions/0077-selection-history.md).
public struct UncheckedSendable<Value>: @unchecked Sendable {
    public let value: Value

    public init(_ value: Value) {
        self.value = value
    }
}
