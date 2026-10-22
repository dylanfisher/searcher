import Base
import Browser
import Foundation

extension BenchCase {
    /// Opening a folder through `ListingService`, timed from the request to each update reaching
    /// the main actor: first rows (B2) and the full sorted listing (B5). Also the memory a loaded
    /// W2 listing holds (B9), and ten W2 loads at once, which is reported only and compared at
    /// M3.4 when the focused pane's load is requested last.
    static let openFolder: [BenchCase] = [
        BenchCase(name: "open W1: first rows", budget: budget("B2.W1"), unit: .milliseconds) {
            try await open($0 ?? w1Path).firstRows
        },
        BenchCase(name: "open W2: first rows", budget: budget("B2.W2"), unit: .milliseconds) {
            try await open($0 ?? w2Path).firstRows
        },
        BenchCase(
            name: "open W2: fully listed and sorted", budget: budget("B5.W2"), unit: .milliseconds
        ) {
            try await open($0 ?? w2Path).full
        },
        BenchCase(name: "open W2: memory held", budget: budget("B9"), unit: .megabytes) {
            try footprintInFreshProcess($0 ?? w2Path)
        },
        BenchCase(name: "open W2 ×10 at once: last first rows", budget: nil, unit: .milliseconds) {
            try await openTen($0 ?? w2Path).reduce(0) { max($0, $1.firstRows) }
        },
        BenchCase(
            name: "open W2 ×10 at once: all fully listed", budget: nil, unit: .milliseconds
        ) {
            try await openTen($0 ?? w2Path).reduce(0) { max($0, $1.full) }
        },
    ]

    /// `Bench --footprint-of-opening <folder>` prints `footprintOfOpening(folder)` and exits.
    static let footprintArgument = "--footprint-of-opening"

    /// The footprint opening `folder` adds, in MB, with the listing still held. Only the first
    /// large load in a process shows it: later loads reuse pages that earlier ones freed, which
    /// stay in the footprint. So the B9 case calls this in a new process for each run.
    static func footprintOfOpening(_ folder: String) async throws -> Double {
        let before = try Footprint.current()
        let opened = try await open(folder)
        let after = try Footprint.current()
        return withExtendedLifetime(opened) { (Double(after) - Double(before)) / 1_048_576 }
    }

    private static func footprintInFreshProcess(_ folder: String) throws -> Double {
        guard let executable = Bundle.main.executableURL else {
            throw FreshProcessFailed(description: "can't find the Bench executable")
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = [footprintArgument, folder]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = String(
            decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0,
            let megabytes = Double(output.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            throw FreshProcessFailed(
                description:
                    "\(executable.path) \(footprintArgument) \(folder) exited \(process.terminationStatus) printing \(output)"
            )
        }
        return megabytes
    }

    struct FreshProcessFailed: Error, CustomStringConvertible {
        let description: String
    }

    private static let w1Path = Fixture(.w1).path.path
    private static let w2Path = Fixture(.w2).path.path

    private static func budget(_ id: String) -> Budget {
        do {
            return try Budget.named(id)
        } catch {
            preconditionFailure("\(error)")
        }
    }

    /// Ten loads of `path` requested together on one service, each timed from the same start.
    private static func openTen(_ path: String) async throws -> [Opened] {
        let service = ListingService()
        let start = ContinuousClock.now
        return try await withThrowingTaskGroup(of: Opened.self) { group in
            for _ in 0..<10 {
                group.addTask { try await open(path, with: service, from: start) }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
    }

    /// Loads `path` and returns once its full listing reaches the main actor.
    private static func open(
        _ path: String, with service: ListingService = ListingService(),
        from start: ContinuousClock.Instant = .now
    ) async throws -> Opened {
        let firstRows = FirstRows()
        return try await withCheckedThrowingContinuation { continuation in
            service.load(Location(path: path)) { update in
                let elapsed = milliseconds(.now - start)
                switch update {
                case .firstBatch:
                    firstRows.milliseconds = firstRows.milliseconds ?? elapsed
                case .full(let listing, _):
                    // A folder read in one batch gets no first batch; its rows appear in full.
                    continuation.resume(
                        returning: Opened(
                            firstRows: firstRows.milliseconds ?? elapsed, full: elapsed,
                            listing: listing))
                case .failed(let error, _):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// One load's times in milliseconds from the request, and its listing.
    private struct Opened: Sendable {
        let firstRows: Double
        let full: Double
        let listing: Listing
    }

    @MainActor
    private final class FirstRows {
        var milliseconds: Double?
    }
}
