import AppKit
import Browser

/// Finder's sidebar glyphs, read once from the system's CoreTypes bundle and shared by every
/// sidebar, as template images that take the list's tint as its symbols do. The files are read
/// on a `BlockingCallThread` (`CoreTypesIcons`) and decoded on the main actor from memory, so no
/// file-system call runs there. Until the read ends, and for a glyph the bundle lacks, a row
/// shows its SF Symbol (docs/decisions/0107-sidebar-favorites.md,
/// docs/decisions/0108-sidebar-locations.md).
@MainActor
final class SidebarIcons {
    static let shared = SidebarIcons()

    /// A glyph Finder's sidebar shows; its raw value names the file in the bundle.
    enum Glyph: String, CaseIterable {
        case applications = "SidebarApplicationsFolder"
        case desktop = "SidebarDesktopFolder"
        case documents = "SidebarDocumentsFolder"
        case downloads = "SidebarDownloadsFolder"
        case home = "SidebarHomeFolder"
        case folder = "SidebarGenericFolder"
        case externalDisk = "SidebarExternalDisk"
        case internalDisk = "SidebarInternalDisk"
        case removableDisk = "SidebarRemovableDisk"
        case server = "SidebarServerDrive"
        /// A connected server's: Finder shows the blank page for a server whose model it has no
        /// glyph for (docs/decisions/0114-server-location.md).
        case genericFile = "SidebarGenericFile"

        /// The SF Symbol a row shows until the glyph is read, or when the bundle lacks it.
        var symbol: String {
            switch self {
            case .applications: "app.dashed"
            case .desktop: "menubar.dock.rectangle"
            case .documents: "doc"
            case .downloads: "arrow.down.circle"
            case .home: "house"
            case .folder: "folder"
            case .externalDisk, .internalDisk, .removableDisk: "externaldrive"
            case .server, .genericFile: "externaldrive.connected.to.line.below"
            }
        }

        /// The glyph for a favorite folder at `path`: a default favorite's own, the generic
        /// folder's for any other.
        static func forFolder(at path: String, home: String) -> Glyph {
            let home = Location(path: home)
            switch path {
            case "/Applications": return .applications
            case home.child(named: "Desktop").folderPath: return .desktop
            case home.child(named: "Documents").folderPath: return .documents
            case home.child(named: "Downloads").folderPath: return .downloads
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
    private var images: [Glyph: NSImage] = [:]
    private var loading: Task<Void, Never>?

    /// `read` gives the bytes of the icon files named; tests replace it.
    init(read: (@Sendable ([String]) async -> [String: Data])? = nil) {
        self.read = read ?? CoreTypesIcons.read
    }

    /// The glyph's template image, or nil until `load` ends or when the bundle lacks it.
    func image(_ glyph: Glyph) -> NSImage? {
        images[glyph]
    }

    /// Reads the glyphs once; every call waits for that one read.
    func load() async {
        if loading == nil {
            loading = Task { [read] in
                let files = await read(Glyph.allCases.map(\.rawValue))
                for glyph in Glyph.allCases {
                    guard let data = files[glyph.rawValue], let image = NSImage(data: data) else {
                        continue
                    }
                    image.isTemplate = true
                    images[glyph] = image
                }
            }
        }
        await loading?.value
    }
}
