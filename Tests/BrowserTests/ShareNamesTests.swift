import Foundation
import Testing

@testable import Browser

/// `smbutil view -N //dylan@HAL9000._smb._tcp.local` on 2026-10-26, as it printed it, with
/// music mounted.
private let hal9000 = [
    "Share                                           Type    Comments",
    "-------------------------------",
    "docker                                          Disk    ",
    "NetBackup                                       Disk    System default shared folder",
    "home                                            Disk    Home directory of dylan",
    "music                                           Disk    System default shared folder",
    "main                                            Disk    ",
    "homes                                           Disk    user home",
    "video                                           Disk    System default shared folder",
    "IPC$                                            Pipe    IPC Service ()",
    "",
    "8 shares listed",
    "",
].joined(separator: "\n")

/// A row as `smbutil` prints one, with `%-48s%-8s%s`: the name padded with spaces to 48 bytes,
/// the type to 8.
private func row(_ name: String, _ type: String = "Disk", _ comment: String = "") -> String {
    func padded(_ text: String, to width: Int) -> String {
        text + String(repeating: " ", count: max(0, width - text.utf8.count))
    }
    return padded(name, to: 48) + padded(type, to: 8) + comment
}

/// `smbutil view` output listing `rows`, with a trailer counting `count` shares.
private func output(_ rows: [String], count: Int? = nil) -> Data {
    let lines =
        [
            "Share                                           Type    Comments",
            "-------------------------------",
        ] + rows
        + ["", "\(count ?? rows.count) shares listed", ""]
    return Data(lines.joined(separator: "\n").utf8)
}

@Test func thisMachinesListKeepsTheSevenDiskSharesInTheServersOrder() throws {
    #expect(
        try ShareNames.parse(Data(hal9000.utf8))
            == ["docker", "NetBackup", "home", "music", "main", "homes", "video"])
}

@Test func aNameOf47Or48OrMoreBytesParsesWithTheLittlePaddingLeft() throws {
    let names = [47, 48, 60].map { String(repeating: "n", count: $0) }
    #expect(try ShareNames.parse(output(names.map { row($0) })).names == names)
    // The 48-byte name runs straight into its type.
    #expect(row(names[1]).hasSuffix("nDisk    "))
}

@Test func aUnicodeNameParsesWhateverItsBytesLeaveForPadding() throws {
    let names = [
        "Ünïcødé 日本語", String(repeating: "é", count: 23), String(repeating: "日", count: 20),
    ]
    #expect(try ShareNames.parse(output(names.map { row($0) })).names == names)
}

@Test func aNameWithASingleOrADoubleSpaceParses() throws {
    let names = ["my share", "two  spaces", "ends Disk", "Pipe dream"]
    #expect(try ShareNames.parse(output(names.map { row($0) })).names == names)
}

@Test func onlyDiskSharesWhoseNameDoesNotEndInADollarAreKept() throws {
    let rows = [
        row("printer", "Printer", "Office"), row("C$", "Disk", "Default share"),
        row("serial", "Comm"), row("IPC$", "Pipe", "IPC Service ()"), row("main"),
    ]
    #expect(try ShareNames.parse(output(rows)) == ["main"])
}

@Test func aServerWithNoSharesListsNone() throws {
    #expect(try ShareNames.parse(output([])) == [])
}

@Test func aCountOtherThanTheRowsIsUnparsable() {
    #expect(throws: ShareListError.unparsable) {
        try ShareNames.parse(output([row("main"), row("music")], count: 3))
    }
}

@Test func outputWithoutTheHeaderIsUnparsable() {
    let headless = Data(([row("main"), "", "1 shares listed", ""]).joined(separator: "\n").utf8)
    #expect(throws: ShareListError.unparsable) { try ShareNames.parse(headless) }
    let noDashes = Data(
        ([
            "Share                                           Type    Comments", row("main"), "",
            "1 shares listed",
        ]).joined(separator: "\n").utf8)
    #expect(throws: ShareListError.unparsable) { try ShareNames.parse(noDashes) }
}

@Test func aTypeOutsideTheKnownSetIsUnparsable() {
    for type in ["Unknown", "PrinterShare", "disk"] {
        #expect(throws: ShareListError.unparsable) {
            try ShareNames.parse(output([row("main"), row("odd", type)]))
        }
    }
}

@Test func invalidUTF8IsUnparsable() {
    var bytes = [UInt8](output([row("main")]))
    bytes[bytes.firstIndex(of: UInt8(ascii: "m"))!] = 0xFF
    #expect(throws: ShareListError.unparsable) { try ShareNames.parse(Data(bytes)) }
}

@Test func textAfterTheTrailerIsUnparsable() {
    var text = String(decoding: output([row("main")]), as: UTF8.self)
    text += "more\n"
    #expect(throws: ShareListError.unparsable) { try ShareNames.parse(Data(text.utf8)) }
}

@Test func namesMatchByCanonicalFormWithoutCase() {
    let decomposed = "Cafe\u{301}"
    let composed = "Caf\u{E9}"
    #expect(decomposed.unicodeScalars.count != composed.unicodeScalars.count)
    #expect(ShareNames.key(decomposed) == ShareNames.key("CAF\u{C9}"))
    #expect(ShareNames.key("Main") == ShareNames.key("main"))
    #expect(ShareNames.key("main") != ShareNames.key("main 1"))
}

/// A server chooses its shares' names: one that isn't a single path component, or that holds a
/// control or text-direction character, is left out and counted, and the rest are kept
/// (docs/decisions/0115-server-shares.md).
@Test func aNameNoRowCanHaveIsLeftOutAndCounted() throws {
    let unusable = [
        "a/b", ".", "..", "tab\there", "bell\u{7}", "evil\u{202E}txt.exe", "iso\u{2066}late",
        "pop\u{2069}", "mark\u{200F}",
    ]
    let list = try ShareNames.parse(output((["main"] + unusable + ["music"]).map { row($0) }))

    #expect(list == ShareList(names: ["main", "music"], unusableCount: unusable.count))
    #expect(unusable.allSatisfy { !ShareNames.isUsable($0) })
    #expect(ShareNames.isUsable("Ünïcødé 日本語"))
    #expect(ShareNames.isUsable("two  spaces"))
}
