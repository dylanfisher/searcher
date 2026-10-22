// Breaks the display-name rule of scripts/arch, with the call split across lines. Never
// compiled.
import Foundation

func rootName(_ manager: FileManagerLike) -> String {
    manager.displayName(
        atPath: "/")
}

protocol FileManagerLike {
    func displayName(atPath path: String) -> String
}
