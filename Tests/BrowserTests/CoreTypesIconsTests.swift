import Foundation
import Testing

@testable import Browser

@Test func theCoreTypesBundleGivesFindersSidebarGlyphsAndNothingForAMissingOne() async {
    let files = await CoreTypesIcons.read(["SidebarApplicationsFolder", "SidebarNoSuchGlyph"])

    #expect(files.keys.sorted() == ["SidebarApplicationsFolder"])
    #expect(files["SidebarApplicationsFolder"]?.isEmpty == false)
}
