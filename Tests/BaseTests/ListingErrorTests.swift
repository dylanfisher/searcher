import Base
import Darwin
import Testing

/// Privacy protection (TCC) returns EPERM; Unix permissions return EACCES. Full Disk Access helps
/// with the first only, so the two have different reasons.
@Test func privacyProtectionAndUnixPermissionsHaveDifferentReasons() {
    let privacy = ListingError(path: "/Users/me/Library/Mail", code: EPERM).reason
    let unix = ListingError(path: "/private/var/root", code: EACCES).reason

    #expect(privacy != unix)
    #expect(privacy == .privacyProtected)
    #expect(unix == .permissionDenied)
}
