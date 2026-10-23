// Breaks the check-reachable rule of scripts/arch. Never compiled.
import Foundation

func exists(_ url: URL) -> Bool {
    (try? url.checkResourceIsReachable()) ?? false
}
