/// Where the palette's items come from. The palette asks every source again on each key, so a
/// source's items follow what it reads at once: a command registered while the palette is open
/// shows at the next key.
///
/// A sync source hands over its items before `gather` returns, from what it holds in memory; it
/// makes no file-system call. A streaming source hands over what it has before returning, then
/// more as work off the main actor finds it, each time all its items so far. The palette drops
/// a hand-over for a query it has moved on from, so a source needn't check.
@MainActor
public protocol PaletteSource {
    /// Gathers the items for `query` and hands them to `deliver`, which replaces whatever the
    /// source handed over for the query before.
    func gather(_ query: String, deliver: @escaping @MainActor ([PaletteItem]) -> Void)
    /// Stops a streaming source's work, as the palette closes. A sync source has none.
    func cancel()
}
