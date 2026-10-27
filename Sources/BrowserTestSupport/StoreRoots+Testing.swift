import Browser
import TestSupport

/// Store roots inside `folder`, which takes the stores' files with it when the test removes it.
public func roots(_ folder: TemporaryFolder) -> StoreRoots {
    StoreRoots(
        caches: folder.url.appending(path: "Caches"),
        applicationSupport: folder.url.appending(path: "Application Support"))
}
