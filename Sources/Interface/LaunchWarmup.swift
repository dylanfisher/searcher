import AppKit
import CoreText
import os

/// Work done once per process, after the first window has drawn, so that the cost CoreText pays
/// the first time it draws a script doesn't land in a later frame as a stall
/// (0024-launch-warmup.md).
///
/// Off the main thread it draws a sample of each script the fixtures and a music library use, in
/// the list's font, which loads the fallback fonts and their glyph tables. It shows no window and
/// takes no focus.
@MainActor
public final class LaunchWarmup {
    /// The app's warm-up: one per process.
    public static let shared = LaunchWarmup()

    /// One name per script: "Ünïcødé" and "日本語" are copied from the W1–W3 fixtures' words in
    /// `Sources/Bench/Fixture.swift`, which Interface can't import; the rest are scripts a music
    /// library's artist and album names commonly use.
    nonisolated static let samples = [
        "Ünïcødé Ærø Łódź", "日本語 ひらがな カタカナ", "中文 简体 繁體", "한국어", "Русский",
        "Ελληνικά", "العربية", "עברית", "ไทย", "हिन्दी",
    ]

    private let work: @MainActor (NSWindow) async -> Void
    /// Set by the first `start`; later calls see it and do nothing.
    private var task: Task<Void, Never>?

    /// `work` stands in for the warm-up in tests; it gets the window whose frame it waited for.
    init(work: @escaping @MainActor (NSWindow) async -> Void) {
        self.work = work
    }

    /// The warm-up, which calls `draw` for each sample, off the main thread, with the list's font
    /// and a bitmap context at the window's scale. Tests pass their own `draw` to see the calls.
    convenience init(
        draw: @escaping @Sendable (_ sample: String, _ font: CTFont, _ context: CGContext) -> Void =
            LaunchWarmup.drawLine
    ) {
        self.init { window in await Self.drawSamples(for: window, with: draw) }
    }

    /// Runs the warm-up in a run loop pass after the one that commits `window`'s first drawn
    /// frame, so it never delays that frame. Only the first call does anything.
    public func start(after window: NSWindow) {
        guard task == nil else { return }
        let work = work
        task = Task {
            await withCheckedContinuation { continuation in
                FrameCommitTimer.time(from: FrameCommitTimer.now, in: window) { _ in
                    continuation.resume()
                }
            }
            await work(window)
        }
    }

    /// Returns once the warm-up has run. The UI bench waits for it before its first span after
    /// launch, as a person's first click comes later than the warm-up ends.
    public func finished() async {
        guard let task else {
            preconditionFailure("LaunchWarmup.finished() called before start(after:)")
        }
        await task.value
    }

    // MARK: Drawing

    /// Draws every sample with `draw` on a detached task and logs how long that took.
    private static func drawSamples(
        for window: NSWindow,
        with draw: @escaping @Sendable (String, CTFont, CGContext) -> Void
    ) async {
        let size = NSFont.systemFontSize
        let scale = window.backingScaleFactor
        let elapsed = await Task.detached(priority: .utility) {
            ContinuousClock().measure {
                // `NSTextField` labels use the system font at this size.
                guard let font = CTFontCreateUIFontForLanguage(.system, size, nil) else {
                    preconditionFailure("CoreText has no system UI font at \(size) pt")
                }
                guard
                    let context = CGContext(
                        data: nil, width: Int(400 * scale), height: Int(2 * size * scale),
                        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                            | CGBitmapInfo.byteOrder32Little.rawValue)
                else {
                    preconditionFailure("could not make a bitmap context to draw the samples in")
                }
                context.scaleBy(x: scale, y: scale)
                for sample in samples {
                    draw(sample, font, context)
                }
            }
        }.value
        Logger(category: "warmup").notice(
            "launch warm-up: \(Int((elapsed / .milliseconds(1)).rounded()), privacy: .public) ms off the main thread"
        )
    }

    /// Draws `sample` in `font`, so CoreText picks and loads its fallback font, shapes it and
    /// rasterizes its glyphs.
    private nonisolated static func drawLine(_ sample: String, _ font: CTFont, _ context: CGContext)
    {
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: sample, attributes: [.font: font]))
        context.textPosition = CGPoint(x: 0, y: CTFontGetSize(font) / 2)
        CTLineDraw(line, context)
    }
}
