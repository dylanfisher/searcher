import AppKit
import Browser

/// The icons of Finder's sidebar, shared by every sidebar, as template images that take the
/// list's tint. Finder on macOS 26 draws its rows as thin outline SF Symbols; only its
/// Applications glyph has no public symbol, so that one is Finder's own, read once from the
/// system's CoreTypes bundle on a `BlockingCallThread` (`CoreTypesIcons`) and decoded on the main
/// actor from memory, so no file-system call runs there. Until the read ends, or when the bundle
/// lacks it, its row shows a stand-in symbol (docs/decisions/0138-sidebar-outline-symbols.md).
@MainActor
final class SidebarIcons {
    static let shared = SidebarIcons()

    /// A kind of row Finder's sidebar draws its own icon for.
    enum Glyph: CaseIterable {
        case applications
        case desktop
        case documents
        case downloads
        case home
        case folder
        case externalDisk
        case internalDisk
        case removableDisk
        case server
        /// A connected server's: Finder shows the blank page for a server whose model it has no
        /// glyph for (docs/decisions/0114-server-location.md).
        case genericFile

        /// The SF Symbol Finder draws for it on macOS 26; for Applications, which Finder draws
        /// with a private symbol, the stand-in shown until its file is read.
        var symbol: String {
            switch self {
            case .applications: "app.dashed"
            case .desktop: "dock.rectangle"
            case .documents, .genericFile: "doc"
            case .downloads: "arrow.down.circle"
            case .home: "house"
            case .folder: "folder"
            case .externalDisk, .removableDisk: "externaldrive"
            case .internalDisk: "internaldrive"
            case .server: "externaldrive.connected.to.line.below"
            }
        }

        /// The CoreTypes file that holds Finder's own glyph, for the one kind no public symbol
        /// draws.
        var coreTypesFile: String? {
            self == .applications ? "SidebarApplicationsFolder" : nil
        }

        /// The glyph for a favorite folder at `path`: a default favorite's own, the generic
        /// folder's for any other.
        static func forFolder(at path: String, home: String) -> Glyph {
            let home = Location(path: home)
            switch path {
            case "/Applications": return .applications
            case home.folderChild(named: "Desktop").folderPath: return .desktop
            case home.folderChild(named: "Documents").folderPath: return .documents
            case home.folderChild(named: "Downloads").folderPath: return .downloads
            case home.folderPath: return .home
            default: return .folder
            }
        }

        /// The glyph for a volume, as Finder picks: a server for a share, a removable disk for
        /// a card or disc, an external disk for a disk off the internal bus or a disk image, and
        /// an internal disk otherwise.
        static func forVolume(_ volume: SidebarVolume) -> Glyph {
            if volume.kind == .network { return .server }
            if volume.isInternal == true {
                return volume.isRemovable || volume.isEjectable ? .removableDisk : .internalDisk
            }
            return .externalDisk
        }
    }

    private let read: @Sendable ([String]) async -> [String: Data]
    private let symbols: [Glyph: NSImage]
    private var files: [Glyph: NSImage] = [:]
    private var loading: Task<Void, Never>?

    /// `read` gives the bytes of the icon files named; tests replace it.
    init(read: (@Sendable ([String]) async -> [String: Data])? = nil) {
        self.read = read ?? CoreTypesIcons.read
        symbols = Dictionary(
            uniqueKeysWithValues: Glyph.allCases.map { glyph in
                guard
                    let image = NSImage(
                        systemSymbolName: glyph.symbol, accessibilityDescription: nil)
                else { preconditionFailure("the system has no \(glyph.symbol) symbol") }
                return (glyph, image)
            })
    }

    /// The glyph's template image: Finder's file once read, its symbol otherwise.
    func image(_ glyph: Glyph) -> NSImage {
        if let file = files[glyph] { return file }
        guard let symbol = symbols[glyph] else { preconditionFailure("no symbol for \(glyph)") }
        return symbol
    }

    /// Reads the files once; every call waits for that one read.
    func load() async {
        if loading == nil {
            loading = Task { [read] in
                let withFiles = Glyph.allCases.filter { $0.coreTypesFile != nil }
                let read = await read(withFiles.compactMap(\.coreTypesFile))
                for glyph in withFiles {
                    guard let name = glyph.coreTypesFile, let data = read[name],
                        let image = NSImage(data: data)
                    else { continue }
                    image.isTemplate = true
                    files[glyph] = image
                }
            }
        }
        await loading?.value
    }
}
