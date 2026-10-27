import Base
import Testing

@Test func preconditionOffMainPassesOffTheMainThread() async {
    await Task.detached { preconditionOffMain("PreconditionOffMainTests") }.value
}

@Test func preconditionOffMainTrapsOnTheMainThread() async {
    await #expect(processExitsWith: .failure) {
        await MainActor.run { preconditionOffMain("PreconditionOffMainTests") }
    }
}
