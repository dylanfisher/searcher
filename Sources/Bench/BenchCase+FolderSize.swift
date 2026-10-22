import Base
import Browser
import Foundation

extension BenchCase {
    /// A folder size through `FolderSizeService`, timed from the request to the size reaching the
    /// main actor: the recursive part of B5, on W3's ~60k files in ~8k folders. Each run uses a
    /// new cache, so every run walks. A `--path` folder replaces W3.
    static let folderSize: [BenchCase] = [
        BenchCase(name: "walk W3: folder size", budget: budget("B5.W3"), unit: .milliseconds) {
            try await timeWalk($0 ?? w3Path)
        }
    ]

    private static let w3Path = Fixture(.w3).path.path

    private static func timeWalk(_ path: String) async throws -> Double {
        let service = FolderSizeService(
            cache: FolderSizeCache(store: nil), log: { print("folder size: \($0)") })
        let start = ContinuousClock.now
        return try await withCheckedThrowingContinuation { continuation in
            service.requestSize(of: path, modified: Date(), for: PaneID()) { result in
                let elapsed = milliseconds(.now - start)
                continuation.resume(with: result.map { _ in elapsed })
            }
        }
    }
}
