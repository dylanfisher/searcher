import Base
import Foundation

extension Pane {
    /// The least time from one batch of folder sizes reaching the rows to the next.
    public static let sizeBatchInterval: Duration = .milliseconds(250)

    /// Whether `calculateSizes()` can run: a list pane at a folder with a size service. A
    /// server's shares are mount points, and a walk of one would read the whole share
    /// (docs/decisions/0114-server-location.md).
    public var canCalculateSizes: Bool {
        folderSizes != nil && viewMode == .list && location.isFolder
    }

    /// Whether folder rows show walked sizes: a list pane with a size service, with the setting
    /// on or in a folder `calculateSizes()` walked.
    public var showsFolderSizes: Bool {
        canCalculateSizes
            && (settings.folderSizes || calculatedFolders.contains(ExactName(location.folderPath)))
    }

    /// Whether a folder row without a size waits for a walk, and shows pending text: the setting
    /// is on, or the walks `calculateSizes()` asked for haven't all landed. Otherwise it shows no
    /// size.
    public var awaitsFolderSizes: Bool {
        showsFolderSizes
            && (settings.folderSizes || calculatesSizesOnce || !calculatingSizes.isEmpty)
    }

    /// Whether the pane scans its rows now, for walks to ask for and kept sizes to show: it shows
    /// folder sizes, is in the selected tab, and its volume is mounted. A hidden tab's pane
    /// mustn't hold a share's one walk while the focused pane waits for sizes.
    private var walksFolders: Bool {
        showsFolderSizes && isVisible && !volumeIsGone && !isClosed
    }

    /// Drops the kept sizes of the folder and every folder under it, and walks its subfolders
    /// again once that is done. With the setting off they are walked once, and the folder shows
    /// sizes from then on without walking again. The sizes shown stay until the new ones arrive.
    /// When the drop fails, the service logs why and the pane keeps what it has.
    public func calculateSizes() {
        guard canCalculateSizes, let folderSizes else { return }
        let folder = location
        if !settings.folderSizes { calculatedFolders.insert(ExactName(folder.folderPath)) }
        Task { [weak self] in
            guard await folderSizes.recalculateSizes(under: folder.folderPath) else { return }
            guard let self, self.location == folder, self.showsFolderSizes else { return }
            self.forgetFolderSizes()
            self.calculatesSizesOnce = !self.settings.folderSizes
            // The rows switch to pending text.
            self.sizeSettingChanged = true
            self.startSizeScan()
            self.startSizeBatch()
        }
    }

    /// Cancels the pane's walks. The sizes walked stay, and the folders not walked yet are asked
    /// for again by the next scan. Letting local walks finish, a walk already running on a local
    /// volume goes on and keeps its size for a later visit, without delivering it here.
    func cancelSizeWalks(lettingLocalWalksFinish: Bool = false) {
        if lettingLocalWalksFinish {
            folderSizes?.cancelWaitingWalks(for: sizeWalkOwner)
        } else {
            folderSizes?.cancelWalks(for: sizeWalkOwner)
        }
        sizeGeneration += 1
        if !lettingLocalWalksFinish { runningSizeWalksCancelledAt = sizeGeneration }
        requestedSizes = [:]
        calculatesSizesOnce = false
        calculatingSizes = []
    }

    /// Cancels the pane's walks and forgets the sizes of the folder it shows. The service keeps
    /// the sizes walked, and a later listing of the folder gets them from it.
    func forgetFolderSizes(lettingLocalWalksFinish: Bool = false) {
        cancelSizeWalks(lettingLocalWalksFinish: lettingLocalWalksFinish)
        knownSizes = [:]
        failedSizes = []
        waitingSizes = [:]
    }

    /// `Settings.folderSizes` changed: turned off, the walks stop and the rows drop their sizes;
    /// turned on, the folders are walked.
    func followSizeSetting() {
        guard folderSizes != nil, settings.folderSizes != sizeSettingSeen else { return }
        sizeSettingSeen = settings.folderSizes
        if !settings.folderSizes {
            forgetFolderSizes()
            calculatedFolders = []
        }
        sizeSettingChanged = true
        startSizeScan()
        startSizeBatch()
    }

    /// A load that applied known sizes landed after the setting was turned off: the rows drop
    /// them.
    func dropSizesIfOff() {
        guard !showsFolderSizes else { return }
        sizeSettingChanged = true
        startSizeBatch()
    }

    /// Finds, off the main actor, the folder rows not yet walked at their current date and asks
    /// for those walks there, while the setting is on or `calculateSizes()` asked, and finds the
    /// known sizes the rows lack and queues them. Runs after each change of the rows, one scan at
    /// a time.
    func startSizeScan() {
        guard walksFolders, let folderSizes, let listing = state.listing else { return }
        guard !sizeScanIsRunning else {
            sizeScanIsStale = true
            return
        }
        sizeScanIsRunning = true
        let once = calculatesSizesOnce && !settings.folderSizes
        let asksForWalks = settings.folderSizes || once
        let requested = requestedSizes
        let known = knownSizes
        let failed = failedSizes
        let generation = sizeGeneration
        let folder = location
        let owner = sizeWalkOwner
        sizeScanQueue.async { [weak self] in
            var found: [(name: ExactName, modified: Date)] = []
            var missing: [ExactName: Listing.FolderSizeUpdate] = [:]
            for row in 0..<listing.count {
                let entry = listing[row]
                guard entry.type.isFolderOnDisk else { continue }
                let name = ExactName(entry.name)
                if let update = known[name], update.modified == entry.modified {
                    if listing.folderSize(atRow: row) != update.value { missing[name] = update }
                } else if asksForWalks, requested[name] != entry.modified, !failed.contains(name) {
                    found.append((name, entry.modified))
                }
            }
            let asked = found
            let walks = folderSizes.requestSizes(
                of: asked.map { (folder.folderChild(named: $0.name.name).folderPath, $0.modified) },
                in: folder.folderPath, for: owner
            ) { index, result in
                self?.receiveSize(
                    result, of: asked[index].name, modified: asked[index].modified,
                    from: generation)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else {
                        for walk in walks { walk.cancel() }
                        return
                    }
                    self.finishSizeScan(
                        asked: asked, walks: walks, missing: missing, once: once,
                        from: generation)
                }
            }
        }
    }

    private func finishSizeScan(
        asked: [(name: ExactName, modified: Date)], walks: [FolderSizeService.Walk],
        missing: [ExactName: Listing.FolderSizeUpdate], once: Bool, from generation: Int
    ) {
        sizeScanIsRunning = false
        if generation == sizeGeneration, walksFolders {
            for folder in asked { requestedSizes[folder.name] = folder.modified }
            if once {
                // A walk can land before its scan does; those already have their size or failed.
                calculatingSizes = Set(
                    asked.filter { knownSizes[$0.name]?.modified != $0.modified }
                        .map(\.name)
                ).subtracting(failedSizes)
                calculatesSizesOnce = false
                // Rows still without a size switch from pending text once nothing is walked.
                if calculatingSizes.isEmpty { sizeSettingChanged = true }
            }
            waitingSizes.merge(missing) { waiting, _ in waiting }
            startSizeBatch()
        } else {
            // The walks were asked for after the pane cancelled its walks, so that cancel
            // didn't reach them. One that only left the folder lets local walks finish.
            let leftOnly = generation != sizeGeneration && runningSizeWalksCancelledAt <= generation
            for walk in walks {
                if leftOnly { walk.leave() } else { walk.cancel() }
            }
        }
        if sizeScanIsStale {
            sizeScanIsStale = false
            startSizeScan()
        }
    }

    private func receiveSize(
        _ result: Result<FolderSize, ListingError>, of name: ExactName, modified: Date,
        from generation: Int
    ) {
        // A walk the scan asked for can land before the scan does, after a cancel it missed.
        guard generation == sizeGeneration else { return }
        calculatingSizes.remove(name)
        let value: Listing.FolderSizeValue
        switch result {
        case .success(let size):
            value = .size(bytes: size.bytes, isPartial: size.isPartial)
            knownSizes[name] = Listing.FolderSizeUpdate(modified: modified, value: value)
        case .failure:
            value = .failed
            failedSizes.insert(name)
            requestedSizes[name] = nil
        }
        waitingSizes[name] = Listing.FolderSizeUpdate(modified: modified, value: value)
        startSizeBatch()
    }

    /// A batch has sizes to apply, has waited out the interval since the last one, and has rows
    /// to apply them to. It goes before the next patch, so a folder that keeps changing can't hold
    /// sizes back.
    var sizeBatchIsDue: Bool {
        !sizeBatchIsWaiting && (!waitingSizes.isEmpty || sizeSettingChanged)
            && state.listing != nil
    }

    /// Starts a batch that waited for rows once the pass that changed them, and set the selection
    /// beside them, ends. Without it a batch due while there were no rows, such as the one that
    /// drops sizes after the setting went off during a load, would keep patches waiting for good.
    func startSizeBatchAfterThisPass() {
        guard sizeBatchIsDue else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.startSizeBatch() }
        }
    }

    /// Applies the waiting sizes to a copy of the rows off the main actor, as a patch is applied,
    /// and resolves the selection there: rows sorted by size move, and the selection follows its
    /// names. Batches start at most once per `sizeBatchInterval`, and not while a patch, a sort
    /// or another batch runs; each of those starts the next batch when it lands.
    func startSizeBatch() {
        guard sizeBatchIsDue, !patchIsRunning, runningSorts == 0, let listing = state.listing
        else { return }
        let sizes = waitingSizes
        let settingChanged = sizeSettingChanged
        let clearing = !showsFolderSizes
        waitingSizes = [:]
        sizeSettingChanged = false
        // Sizes and patches take turns on the rows, so neither lands on rows the other replaced.
        patchIsRunning = true
        sizeBatchIsWaiting = true
        let version = stateVersion
        let selection = selection
        let selectionVersion = selectionVersion
        rowWorkQueue.async { [weak self] in
            var listing = listing
            if clearing { listing.clearFolderSizes() }
            let changed = listing.applyFolderSizes(sizes) || settingChanged
            let resolved = selection.resolved(in: listing, after: .sameEntries)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.finishSizeBatch(
                        changed ? listing : nil, settingChanged: settingChanged, from: version,
                        resolved: resolved, from: selectionVersion)
                }
            }
        }
        let clock = sizeBatchClock
        Task { [weak self] in
            guard await DeadlineWait.reached({ try await clock.sleep(for: Self.sizeBatchInterval) })
            else { return }
            self?.sizeBatchIsWaiting = false
            self?.startSizeBatch()
        }
    }

    /// Shows the rows with the batch's sizes, nil when none changed, unless a load, patch, sort
    /// or navigation replaced the rows meanwhile. The scan that followed that change queued the
    /// known sizes the new rows lack.
    private func finishSizeBatch(
        _ listing: Listing?, settingChanged: Bool, from version: Int, resolved: Selection,
        from selectionVersion: Int
    ) {
        patchIsRunning = false
        defer {
            startPatch()
            startSizeBatch()
        }
        guard version == stateVersion else {
            sizeSettingChanged = sizeSettingChanged || settingChanged
            return
        }
        guard let listing else { return }
        show(
            state.showing(listing), after: .sameEntries, resolved: resolved, from: selectionVersion)
        startSortIfNeeded()
        reportChange()
    }

    /// `update` with `sizes` applied to its listing, on the load's worker, so a folder listed
    /// again shows the sizes walked for it at once. Folders `sizes` lacks get the sizes
    /// `folderSizes` keeps in memory, so a folder visited again shows its subfolders' sizes with
    /// its first rows; the scan that follows asks for each, and the service's own checks decide
    /// whether it is walked again.
    nonisolated static func applying(
        _ sizes: [ExactName: Listing.FolderSizeUpdate], keptIn folderSizes: FolderSizeService?,
        under folder: Location, to update: ListingUpdate
    ) -> ListingUpdate {
        guard !sizes.isEmpty || folderSizes != nil else { return update }
        func applied(_ listing: Listing) -> Listing {
            var listing = listing
            listing.applyFolderSizes(
                kept(in: listing, from: folderSizes, under: folder).merging(sizes) { _, known in
                    known
                })
            return listing
        }
        switch update {
        case .cached(let listing, let listedAt, let rootVolumeName):
            return .cached(applied(listing), listedAt: listedAt, rootVolumeName: rootVolumeName)
        case .firstBatch(let listing, let rootVolumeName):
            return .firstBatch(applied(listing), rootVolumeName: rootVolumeName)
        case .full(let listing, let rootVolumeName):
            return .full(applied(listing), rootVolumeName: rootVolumeName)
        case .serverListed(let listing, let notice, let rootVolumeName):
            return .serverListed(applied(listing), notice, rootVolumeName: rootVolumeName)
        case .failed, .slow, .gaveUp, .volumeGone, .notConnected:
            return update
        }
    }

    /// The sizes `folderSizes` keeps in memory for the folder rows of `listing`, a listing of
    /// `folder`, at the dates the rows show.
    private nonisolated static func kept(
        in listing: Listing, from folderSizes: FolderSizeService?, under folder: Location
    ) -> [ExactName: Listing.FolderSizeUpdate] {
        guard let folderSizes else { return [:] }
        let folders = (0..<listing.count).map { listing[$0] }.filter { $0.type.isFolderOnDisk }
        let asked = folders.map {
            (path: folder.folderChild(named: $0.name).folderPath, modified: $0.modified)
        }
        var found: [ExactName: Listing.FolderSizeUpdate] = [:]
        for (entry, size) in zip(folders, folderSizes.keptSizes(of: asked)) {
            guard let size else { continue }
            found[ExactName(entry.name)] = Listing.FolderSizeUpdate(
                modified: entry.modified,
                value: .size(bytes: size.bytes, isPartial: size.isPartial))
        }
        return found
    }
}
