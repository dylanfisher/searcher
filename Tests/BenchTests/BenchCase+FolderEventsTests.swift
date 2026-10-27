import Base
import Browser
import Testing

@testable import Bench

@Test func folderEventsCaseIsRegisteredAndReportedOnly() {
    #expect(
        BenchCase.folderEvents.map(\.name) == ["FSEvents batch: 1k deep events and a deep rescan"])
    #expect(BenchCase.folderEvents.allSatisfy { $0.budget == nil })
    let registered = Set(BenchCase.registered.map(\.name))
    #expect(BenchCase.folderEvents.allSatisfy { registered.contains($0.name) })
}

@Test func folderEventsBatchHoldsADeepRescanAndChangesNothingShown() {
    let batch = BenchCase.folderEventsBatch
    #expect(batch.count == 1_001)
    #expect(batch.filter { $0.flags.contains(.mustRescan) }.count == 1)
    #expect(FolderMonitor.change(for: batch, in: BenchCase.folderEventsFolder) == nil)
}
