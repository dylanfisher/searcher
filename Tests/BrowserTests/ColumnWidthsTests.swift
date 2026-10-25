import Testing

@testable import Browser

private func at(_ path: String) -> Location { Location(path: path) }

@Test func aFolderPastTheLimitDropsTheFolderSetLongestAgo() {
    var widths = ColumnWidths()
    for index in 0..<ColumnWidths.folderLimit {
        widths.set(200, of: at("/f\(index)"))
    }
    // Setting the first one again makes it the latest, so the second one goes first.
    widths.set(300, of: at("/f0"))

    widths.set(400, of: at("/new"))

    #expect(widths.folders.count == ColumnWidths.folderLimit)
    #expect(widths.width(of: at("/f1")) == nil)
    #expect(widths.width(of: at("/f0")) == 300)
    #expect(widths.width(of: at("/new")) == 400)
    #expect(widths.folders.last?.location == at("/new"))
}

@Test func settingTheWidthAFolderHasMovesNothing() {
    var widths = ColumnWidths()
    widths.set(200, of: at("/a"))
    widths.set(300, of: at("/b"))

    widths.set(200, of: at("/a"))

    #expect(widths.folders.map(\.location) == [at("/a"), at("/b")])
}

@Test func theSameWidthsSetInAnotherOrderAreEqual() {
    var one = ColumnWidths()
    one.set(200, of: at("/a"))
    one.set(300, of: at("/b"))
    var other = ColumnWidths()
    other.set(300, of: at("/b"))
    other.set(200, of: at("/a"))

    #expect(one == other)
    other.setPreview(250)
    #expect(one != other)
    other.set(201, of: at("/a"))
    one.setPreview(250)
    #expect(one != other)
}

@Test func storedWidthsWithAFolderTwiceTooManyOutOfRangeOrFractionalHaveAProblem() {
    let folder = { (path: String, width: Double) in
        ColumnWidths.Folder(location: at(path), width: width)
    }
    #expect(ColumnWidths.problem(folders: [folder("/a", 200)], preview: 300) == nil)
    #expect(
        ColumnWidths.problem(folders: [folder("/a", 200), folder("/a", 300)], preview: nil) != nil)
    #expect(
        ColumnWidths.problem(
            folders: (0...ColumnWidths.folderLimit).map { folder("/f\($0)", 200) }, preview: nil)
            != nil)
    #expect(ColumnWidths.problem(folders: [folder("/a", 99)], preview: nil) != nil)
    #expect(ColumnWidths.problem(folders: [], preview: 1001) != nil)
    #expect(ColumnWidths.problem(folders: [folder("/a", .nan)], preview: nil) != nil)
    #expect(ColumnWidths.problem(folders: [folder("/a", 200.5)], preview: nil) != nil)
    #expect(ColumnWidths.problem(folders: [], preview: 286.25) != nil)
}

/// A column can be narrower than the preview: a width below `Settings.previewWidths` is stored
/// for a folder but not for the preview.
@Test func storedPreviewWidthsBelowThePreviewsMinimumHaveAProblem() {
    let narrow = Settings.previewWidths.lowerBound - 1
    #expect(Settings.isColumnWidth(narrow))
    #expect(
        ColumnWidths.problem(
            folders: [ColumnWidths.Folder(location: at("/a"), width: narrow)], preview: nil)
            == nil)
    #expect(ColumnWidths.problem(folders: [], preview: narrow) != nil)
    #expect(ColumnWidths.problem(folders: [], preview: Settings.previewWidths.lowerBound) == nil)
}
