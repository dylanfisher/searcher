import Base
import CoreGraphics
import Foundation

/// A `ThumbnailMaking` for tests. Each request is recorded and held until the test answers its
/// path, with an image or with none; a path answered before it is asked for is answered at once.
/// A request stopped while held is recorded as stopped; answering it later still calls back, as
/// Quick Look may.
/// Tests use it to hold a thumbnail in flight and to see which files were asked for, and that
/// none was asked for on the main thread.
public final class GatedThumbnailMaker: ThumbnailMaking, @unchecked Sendable {
    /// One `makeThumbnail` call, as it started.
    public struct Call: Sendable, Equatable {
        public let path: String
        public let side: Double
        public let scale: Double
        public let onMainThread: Bool
        public let onBlockingCallThread: Bool

        public init(
            path: String, side: Double, scale: Double, onMainThread: Bool,
            onBlockingCallThread: Bool
        ) {
            self.path = path
            self.side = side
            self.scale = scale
            self.onMainThread = onMainThread
            self.onBlockingCallThread = onBlockingCallThread
        }
    }

    // `lock` guards everything below.
    private let lock = NSLock()
    private var answers: [String: CGImage?] = [:]
    private var held: [String: [@Sendable (CGImage?) -> Void]] = [:]
    private var startedCalls: [Call] = []
    private var stoppedPaths: [String] = []

    public init() {}

    public func makeThumbnail(
        at path: String, side: Double, scale: Double,
        done: @escaping @Sendable (CGImage?) -> Void
    ) -> @Sendable () -> Void {
        let answer: CGImage?? = lock.withLock {
            startedCalls.append(
                Call(
                    path: path, side: side, scale: scale, onMainThread: Thread.isMainThread,
                    onBlockingCallThread: BlockingCallThread.isCurrent))
            if let answer = answers[path] { return .some(answer) }
            held[path, default: []].append(done)
            return nil
        }
        if let answer { done(answer) }
        return { [self] in lock.withLock { stoppedPaths.append(path) } }
    }

    /// The paths of the requests stopped so far, in the order stopped.
    public var stopped: [String] {
        lock.withLock { stoppedPaths }
    }

    /// Answers every request for `path`, held now or made later, with `image`, or with none.
    public func answer(_ path: String, with image: CGImage?) {
        let waiting = lock.withLock {
            answers[path] = .some(image)
            return held.removeValue(forKey: path) ?? []
        }
        for done in waiting { done(image) }
    }

    /// Holds the requests for `path` made from now on until `answer` is called again, undoing
    /// an earlier answer.
    public func hold(_ path: String) {
        lock.withLock { answers[path] = nil }
    }

    /// Every call so far, in the order they started.
    public var calls: [Call] {
        lock.withLock { startedCalls }
    }

    /// The paths asked for so far, in the order asked.
    public var paths: [String] { calls.map(\.path) }

    /// Suspends until `count` calls have started, and returns false if `timeout` passes first.
    public nonisolated(nonsending) func waitForCalls(_ count: Int, timeout: TimeInterval = 5)
        async -> Bool
    {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while lock.withLock({ startedCalls.count < count }) {
            if Date() >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return true
    }
}

/// A plain image `pixels` wide and `height` tall, square without one, for a test to answer a
/// thumbnail request with.
public func testThumbnail(pixels: Int = 32, height: Int? = nil) -> CGImage {
    guard
        let context = CGContext(
            data: nil, width: pixels, height: height ?? pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
        let image = context.makeImage()
    else { preconditionFailure("couldn't draw a \(pixels)-pixel test image") }
    return image
}
