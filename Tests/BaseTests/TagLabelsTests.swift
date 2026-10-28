import Testing

@testable import Base

@Test func tagLabelsKeepEachColorOnceInOrderAndSkipTagsWithoutOne() {
    let labels = TagLabels([7, 0, 6, 7, 4])

    #expect(Array(labels) == [7, 6, 4])
    #expect(labels.count == 3)
    #expect(!labels.isEmpty)
    #expect(TagLabels([0, 0]).isEmpty)
    #expect(TagLabels([]) == TagLabels([0]))
}

@Test func tagLabelsHoldAllSevenColors() {
    let all = [6, 7, 5, 2, 4, 3, 1]

    #expect(Array(TagLabels(all)) == all)
    #expect(Array(TagLabels(all + all)) == all)
}

@Test func tagLabelsFitInTheEntrysPaddingSoTheEntryIsNoLarger() {
    #expect(MemoryLayout<TagLabels>.size == 4)
    // The size before tags: the name, the type and two flags, the size and the date.
    #expect(MemoryLayout<DirectoryEntry>.stride == 48)
}
