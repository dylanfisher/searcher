import Base
import Testing

@Test func splitsAbsolutePath() {
    #expect(pathComponents("/Users//me/") == ["Users", "me"])
}
