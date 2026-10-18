//
//  MenuBarItemImageCache.swift
//  Ice
//

import Cocoa
import Combine
import OSLog

/// Cache for menu bar item images.
final class MenuBarItemImageCache: ObservableObject {
    /// A representation of a captured menu bar item image.
    struct CapturedImage: Hashable {
        /// The base image.
        let cgImage: CGImage

        /// The scale factor of the image at the time of capture.
        let scale: CGFloat

        /// The image's size, applying ``scale``.
        var scaledSize: CGSize {
            CGSize(
                width: CGFloat(cgImage.width) / scale,
                height: CGFloat(cgImage.height) / scale
            )
        }

        /// The base image, converted to an `NSImage` and applying ``scale``.
        var nsImage: NSImage {
            NSImage(cgImage: cgImage, size: scaledSize)
        }

        /// Returns a Boolean value that indicates whether this image has the
        /// same scale, size, pixel format and pixels as the given image.
        ///
        /// `==` compares the base images by identity, so a capture of an item
        /// that hasn't changed is never equal to the image it replaces. This
        /// compares the bytes of every pixel instead.
        func hasSamePixels(as other: CapturedImage) -> Bool {
            if self == other {
                return true
            }
            let a = cgImage
            let b = other.cgImage
            guard
                scale == other.scale,
                a.width == b.width,
                a.height == b.height,
                a.width > 0,
                a.height > 0,
                a.bitsPerComponent == b.bitsPerComponent,
                a.bitsPerPixel == b.bitsPerPixel,
                a.bytesPerRow == b.bytesPerRow,
                a.bitmapInfo == b.bitmapInfo,
                a.colorSpace == b.colorSpace,
                a.renderingIntent == b.renderingIntent,
                a.shouldInterpolate == b.shouldInterpolate,
                a.isMask == b.isMask,
                a.decode == nil,
                b.decode == nil,
                let dataA = a.dataProvider?.data,
                let dataB = b.dataProvider?.data,
                let bytesA = CFDataGetBytePtr(dataA),
                let bytesB = CFDataGetBytePtr(dataB)
            else {
                return false
            }
            // Compare row by row, leaving out the padding at the end of each row.
            // A crop's data starts at its first pixel and keeps the rows of the
            // image it was cropped from, so it can be longer than the crop.
            let bytesPerRow = a.bytesPerRow
            let rowLength = (a.width * a.bitsPerPixel + 7) / 8
            let requiredLength = (a.height - 1) * bytesPerRow + rowLength
            guard
                CFDataGetLength(dataA) >= requiredLength,
                CFDataGetLength(dataB) >= requiredLength
            else {
                return false
            }
            for row in 0..<a.height {
                let offset = row * bytesPerRow
                if memcmp(bytesA + offset, bytesB + offset, rowLength) != 0 {
                    return false
                }
            }
            return true
        }
    }

    /// The result of an image capture operation.
    ///
    /// Marked `@unchecked Sendable` so it can be returned from the capture queue
    /// below. The images it holds are immutable once captured.
    private struct CaptureResult: @unchecked Sendable {
        /// The successfully captured images.
        var images = [MenuBarItemTag: CapturedImage]()

        /// The menu bar items excluded from the capture.
        var excluded = [MenuBarItem]()
    }

    /// The queue the blocking window-server capture calls run on.
    ///
    /// Capturing a window is a synchronous call that can block indefinitely: on
    /// macOS 26 the per-window path is proxied through ScreenCaptureKit, and a
    /// capture of an item that is off the edge of the menu bar never returns.
    ///
    /// Running those calls on the Swift concurrency pool is what froze the app.
    /// Every cooperative thread ended up parked inside one — a sample showed all
    /// ten of them in `SLSWindowListCreateImageFromArrayProxying` — so no further
    /// task could be scheduled, while the main thread sat idle in its run loop.
    /// The app looked hung but was merely unable to run any work.
    ///
    /// Wrapping the call in `Task.withTimeout` does not help, and did not: the
    /// task is abandoned, but the thread it left behind stays blocked forever.
    /// The only remedy is to keep these calls off the cooperative pool entirely.
    /// The queue is serial, so a stuck capture costs one thread rather than one
    /// per item.
    private static let captureQueue = DispatchQueue(
        label: "com.jordanbaird.Ice.ImageCapture",
        qos: .userInitiated
    )

    /// Runs a blocking capture off the Swift concurrency pool.
    private nonisolated func onCaptureQueue(
        _ work: @escaping @Sendable () -> CaptureResult
    ) async -> CaptureResult {
        await withCheckedContinuation { continuation in
            Self.captureQueue.async {
                continuation.resume(returning: work())
            }
        }
    }

    /// The cached item images, keyed by their corresponding tags.
    @Published private(set) var images = [MenuBarItemTag: CapturedImage]()

    /// Sends after every update of the cache, including the updates that
    /// leave ``images`` unchanged and so don't publish it.
    let updates = PassthroughSubject<Void, Never>()

    /// The item cache at the time ``images`` was last published.
    private var itemCacheAtLastPublish: MenuBarItemManager.ItemCache?

    /// Logger for the menu bar item image cache.
    private let logger = Logger(category: "MenuBarItemImageCache")

    /// Queue to run cache operations.
    private let queue = DispatchQueue(label: "MenuBarItemImageCache", qos: .background)

    /// Image capture options.
    private let captureOption: CGWindowImageOption = [.boundsIgnoreFraming, .bestResolution]

    /// The shared app state.
    private weak var appState: AppState?

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    // MARK: Setup

    /// Sets up the cache.
    @MainActor
    func performSetup(with appState: AppState) {
        self.appState = appState
        configureCancellables()
    }

    /// Configures the internal observers for the cache.
    @MainActor
    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        if let appState {
            let navigationState = appState.navigationState

            Publishers.Merge3(
                // Update every 3 seconds at minimum, while the images can be on
                // screen. ``updateCache()`` does nothing otherwise. The pane shown
                // in Settings is left out of the condition, so that switching to
                // Menu Bar Layout finds the timer already running, as it did when
                // the timer always ran.
                Publishers.CombineLatest4(
                    navigationState.$isIceBarPresented,
                    navigationState.$isSearchPresented,
                    navigationState.$isAppFrontmost,
                    navigationState.$isSettingsPresented
                )
                .map { isIceBarPresented, isSearchPresented, isAppFrontmost, isSettingsPresented in
                    isIceBarPresented || isSearchPresented || (isAppFrontmost && isSettingsPresented)
                }
                .removeDuplicates()
                .map { isNeeded -> AnyPublisher<Void, Never> in
                    guard isNeeded else {
                        return Empty().eraseToAnyPublisher()
                    }
                    return Timer.publish(every: 3, tolerance: 0.5, on: .main, in: .default)
                        .autoconnect()
                        .replace(with: ())
                        .eraseToAnyPublisher()
                }
                .switchToLatest(),

                // Update when the active space or screen parameters change.
                Publishers.Merge(
                    NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification),
                    NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
                )
                .replace(with: ()),

                // Update when the average menu bar color or cached items change.
                Publishers.Merge(
                    appState.menuBarManager.$averageColorInfo.removeDuplicates().replace(with: ()),
                    appState.itemManager.$itemCache.removeDuplicates().replace(with: ())
                )
            )
            .throttle(for: 0.5, scheduler: DispatchQueue.main, latest: false)
            .sink { [weak self] in
                guard let self else {
                    return
                }
                Task {
                    await self.updateCache()
                }
            }
            .store(in: &c)
        }

        cancellables = c
    }

    // MARK: Capturing Images

    /// The widest composite capture, in pixels, that the window server returns.
    /// A wider one returns `nil`.
    private static let maxCompositeWidth: CGFloat = 16384

    /// Captures composite images of the given sections' items, then crops out
    /// an image for each item and returns the result.
    ///
    /// Takes one composite per menu bar row. A composite covers the bounding
    /// box of its windows, so one composite of windows on two rows (the menu
    /// bars of two displays, while the active menu bar moves between them)
    /// also covers all the empty space between the rows: with one display above
    /// the other, tens of megabytes, which every crop below keeps alive. Windows
    /// on different rows never overlap, so each crop has the same pixels either way.
    ///
    /// The sections that share a row share its composite, as long as the
    /// composite stays narrow enough to be captured. If it can't be captured,
    /// each section in it is captured on its own.
    private nonisolated func compositeCapture(_ sections: [[MenuBarItem]], scale: CGFloat) -> CaptureResult {
        var result = CaptureResult()

        // The windows of each row, as one group per section, in their original
        // order, and the index of each row in `rows`, keyed by the top edge its
        // windows share.
        var rows = [[[(item: MenuBarItem, bounds: CGRect)]]]()
        var rowIndices = [CGFloat: Int]()

        for items in sections {
            // The index of this section's group in each row it has windows on.
            var groupIndices = [Int: Int]()

            for item in items {
                // Don't use `item.bounds`, it could be out of date.
                guard let bounds = Bridging.getWindowBounds(for: item.windowID) else {
                    result.excluded.append(item)
                    continue
                }

                let rowIndex: Int
                if let index = rowIndices[bounds.minY] {
                    rowIndex = index
                } else {
                    rowIndex = rows.count
                    rowIndices[bounds.minY] = rowIndex
                    rows.append([])
                }

                if let groupIndex = groupIndices[rowIndex] {
                    rows[rowIndex][groupIndex].append((item, bounds))
                } else {
                    groupIndices[rowIndex] = rows[rowIndex].count
                    rows[rowIndex].append([(item, bounds)])
                }
            }
        }

        for row in rows {
            // Batch the row's groups, in order, while the batch's composite fits.
            var batch = [[(item: MenuBarItem, bounds: CGRect)]]()
            var batchUnion = CGRect.null

            for group in row {
                let groupUnion = group.reduce(CGRect.null) { $0.union($1.bounds) }
                if !batch.isEmpty, batchUnion.union(groupUnion).width * scale > Self.maxCompositeWidth {
                    compositeCapture(batch: batch, into: &result)
                    batch.removeAll()
                    batchUnion = .null
                }
                batch.append(group)
                batchUnion = batchUnion.union(groupUnion)
            }

            compositeCapture(batch: batch, into: &result)
        }

        return result
    }

    /// Captures one composite image of the given groups of windows, which are
    /// on one menu bar row, and adds the cropped item images to `result`.
    ///
    /// If that composite fails, captures each group on its own, so that every
    /// group gets the result it gets when no other group shares its row.
    private nonisolated func compositeCapture(
        batch: [[(item: MenuBarItem, bounds: CGRect)]],
        into result: inout CaptureResult
    ) {
        if batch.count > 1, let rowResult = compositeCapture(row: batch.flatMap { $0 }) {
            result.images.merge(rowResult.images) { (_, new) in new }
            result.excluded += rowResult.excluded
            return
        }

        for group in batch {
            guard let groupResult = compositeCapture(row: group) else {
                result.excluded += group.map(\.item) // Exclude all items in the group.
                continue
            }
            result.images.merge(groupResult.images) { (_, new) in new }
            result.excluded += groupResult.excluded
        }
    }

    /// Captures a composite image of the given windows, which are on one menu
    /// bar row, then crops out an image for each item and returns the result.
    ///
    /// Returns `nil` if the composite can't be captured, is transparent, or
    /// has an implausible scale.
    private nonisolated func compositeCapture(row: [(item: MenuBarItem, bounds: CGRect)]) -> CaptureResult? {
        var result = CaptureResult()

        var boundsUnion = CGRect.null
        var windowArea: CGFloat = 0

        for (_, bounds) in row {
            boundsUnion = boundsUnion.union(bounds)
            windowArea += bounds.width * bounds.height
        }

        guard
            let compositeImage = ScreenCapture.captureWindows(with: row.map(\.item.windowID), option: captureOption),
            !compositeImage.isTransparent(),
            boundsUnion.width > 0
        else {
            return nil
        }

        // Derive the scale from the capture rather than trusting the one passed in.
        //
        // The caller's scale comes from whichever display the item cache last
        // recorded, and that briefly disagrees with reality when the active menu
        // bar moves between displays of different densities: the pixels are the
        // new display's, the recorded scale is still the old one's.
        //
        // This used to be an exact equality check — `compositeImage.width ==
        // boundsUnion.width * scale` — which failed on that disagreement and
        // excluded *every* item, sending them all into the individual capture path
        // that blocks. So the same mismatch produced both symptoms: items drawn at
        // twice or half their size, and the freeze. Deriving the scale removes the
        // disagreement instead of detecting it.
        let actualScale = CGFloat(compositeImage.width) / boundsUnion.width
        guard actualScale >= 0.5, actualScale <= 4 else {
            logger.warning("Implausible capture scale \(actualScale, privacy: .public); excluding items")
            return nil
        }

        // Each crop keeps the whole composite alive. When the row holds several
        // sections, the composite spans the gaps between them (thousands of
        // points, where the section dividers push the hidden items), so copy
        // the crops out of it instead. Within one section the windows sit next
        // to each other, and the composite is about the size of its crops.
        let copiesCrops = boundsUnion.width * boundsUnion.height > 2 * windowArea

        // Crop out each item from the composite.
        for (item, bounds) in row {
            let cropRect = CGRect(
                x: (bounds.origin.x - boundsUnion.origin.x) * actualScale,
                y: (bounds.origin.y - boundsUnion.origin.y) * actualScale,
                width: bounds.width * actualScale,
                height: bounds.height * actualScale
            )

            guard
                let image = compositeImage.cropping(to: cropRect),
                !image.isTransparent()
            else {
                result.excluded.append(item)
                continue
            }

            result.images[item.tag] = CapturedImage(
                cgImage: copiesCrops ? (image.copyingPixels() ?? image) : image,
                scale: actualScale
            )
        }

        return result
    }

    /// Captures an image of each of the given items individually, then
    /// returns the result.
    private nonisolated func individualCapture(_ items: [MenuBarItem], scale: CGFloat) -> CaptureResult {
        var result = CaptureResult()

        for item in items {
            // Live bounds, not `item.bounds`: the cached ones can name the display
            // the item was on a moment ago.
            guard
                let bounds = Bridging.getWindowBounds(for: item.windowID),
                bounds.width > 0,
                let image = ScreenCapture.captureWindow(with: item.windowID, option: captureOption),
                !image.isTransparent()
            else {
                result.excluded.append(item)
                continue
            }
            // Derived, for the same reason as in the composite path above.
            let actualScale = CGFloat(image.width) / bounds.width
            result.images[item.tag] = CapturedImage(
                cgImage: image,
                scale: (actualScale >= 0.5 && actualScale <= 4) ? actualScale : scale
            )
        }

        return result
    }

    /// Captures the images of the given sections' menu bar items and returns
    /// the result.
    private nonisolated func captureImages(of sections: [[MenuBarItem]], scale: CGFloat, appState: AppState) async -> CaptureResult {
        // Use individual capture after a move operation, since composite capture
        // doesn't account for overlapping items.
        if await appState.itemManager.lastMoveOperationOccurred(within: .seconds(2)) {
            logger.debug("Capturing individually due to recent item movement")
            let items = sections.flatMap { $0 }
            return await onCaptureQueue { [self] in individualCapture(items, scale: scale) }
        }

        let compositeResult = await onCaptureQueue { [self] in compositeCapture(sections, scale: scale) }

        if compositeResult.excluded.isEmpty {
            return compositeResult // All items captured successfully.
        }

        logger.notice(
            """
            Some items were excluded from composite capture. Attempting to capture \
            excluded items individually: \(compositeResult.excluded, privacy: .public)
            """
        )

        let excluded = compositeResult.excluded
        var individualResult = await onCaptureQueue { [self] in individualCapture(excluded, scale: scale) }

        // Merge the successfully captured images from each result. Keep excluded
        // items as part of the result, so they can be logged elsewhere.
        individualResult.images.merge(compositeResult.images) { (_, new) in new }

        return individualResult
    }

    // MARK: Update Cache

    /// Updates the cache for the given sections, without checking whether
    /// caching is necessary.
    func updateCacheWithoutChecks(sections: [MenuBarSection.Name]) async {
        guard
            let appState,
            await appState.hasPermission(.screenRecording)
        else {
            return
        }

        if #available(macOS 27.0, *) {
            // There are no item windows to capture on macOS 27. See `ItemImageStore27`.
            var items = [MenuBarItem]()
            for section in sections {
                items += await appState.itemManager.itemCache.managedItems(for: section)
            }
            let store = await appState.itemImageStore27
            await store.captureActiveMenuBar(appState: appState)
            await store.photographMissing(items: items, appState: appState)
            var newImages = [MenuBarItemTag: CapturedImage]()
            for item in items {
                if let image = await store.image(for: item) {
                    newImages[item.tag] = image
                }
            }
            await MainActor.run { [newImages] in
                mergeImages(newImages, appState: appState)
            }
            return
        }

        guard
            let displayID = await appState.itemManager.itemCache.displayID,
            let screen = NSScreen.screens.first(where: { $0.displayID == displayID })
        else {
            return
        }

        let scale = screen.backingScaleFactor

        // Capture the items of all sections together, so that sections that
        // share a menu bar row share one composite capture.
        var sectionItems = [(section: MenuBarSection.Name, items: [MenuBarItem])]()

        for section in sections {
            let items = await appState.itemManager.itemCache.managedItems(for: section)
            guard !items.isEmpty else {
                continue
            }
            sectionItems.append((section, items))
        }

        let captureResult = await captureImages(of: sectionItems.map(\.items), scale: scale, appState: appState)
        let excludedTags = Set(captureResult.excluded.map(\.tag))
        var newImages = [MenuBarItemTag: CapturedImage]()

        for (section, items) in sectionItems {
            let excluded = items.filter { excludedTags.contains($0.tag) }
            if !excluded.isEmpty {
                logger.error("Some items failed capture: \(excluded, privacy: .public)")
            }

            let sectionImages = items.compactMap { item in
                captureResult.images[item.tag].map { (item.tag, $0) }
            }

            guard !sectionImages.isEmpty else {
                logger.warning("Failed item image cache for \(section.logString, privacy: .public)")
                continue
            }

            newImages.merge(sectionImages) { (_, new) in new }
        }

        await MainActor.run { [newImages] in
            mergeImages(newImages, appState: appState)
        }
    }

    /// Merges the given images into the cache, dropping the images of items
    /// that no longer exist, so that the cache doesn't grow without bound as
    /// apps come and go.
    ///
    /// When every new image has the same pixels as the cached one, the cached
    /// images are kept, and ``images`` is only published if items were dropped,
    /// or if the item cache changed since it was last published. Every view of
    /// the images redrew on each capture of an unchanged menu bar otherwise.
    /// The views that read the item cache alongside the images, such as the
    /// "Unable to display menu bar items" check, still see each change to it.
    ///
    /// The comparison is all or nothing, rather than per item: a cropped image
    /// keeps the whole capture it was cropped from alive, so keeping some old
    /// images next to some new ones would keep several captures in memory.
    @MainActor
    private func mergeImages(_ newImages: [MenuBarItemTag: CapturedImage], appState: AppState) {
        defer {
            updates.send()
        }

        let itemCache = appState.itemManager.itemCache
        let currentTags = Set(itemCache.managedItems.map(\.tag))

        var merged = images
        // Skip pruning while the item cache is empty, so that every image
        // isn't dropped at once.
        if !currentTags.isEmpty {
            merged = merged.filter { currentTags.contains($0.key) }
        }

        let isUnchanged = newImages.allSatisfy { tag, newImage in
            merged[tag]?.hasSamePixels(as: newImage) == true
        }
        if !isUnchanged {
            merged.merge(newImages) { (_, new) in new }
        }

        guard merged != images || itemCache != itemCacheAtLastPublish else {
            return
        }
        images = merged
        itemCacheAtLastPublish = itemCache
    }

    /// Updates the cache for the given sections, if necessary.
    func updateCache(sections: [MenuBarSection.Name]) async {
        guard let appState else {
            return
        }

        let isIceBarPresented = await appState.navigationState.isIceBarPresented
        let isSearchPresented = await appState.navigationState.isSearchPresented

        if !isIceBarPresented && !isSearchPresented {
            guard
                await appState.navigationState.isAppFrontmost,
                await appState.navigationState.isSettingsPresented,
                await appState.navigationState.settingsNavigationIdentifier == .menuBarLayout
            else {
                return
            }
        }

        guard await !appState.itemManager.lastMoveOperationOccurred(within: .seconds(1)) else {
            logger.debug("Skipping item image cache due to recent item movement")
            return
        }

        await updateCacheWithoutChecks(sections: sections)
    }

    /// Updates the cache for all sections, if necessary.
    func updateCache() async {
        guard let appState else {
            return
        }

        let isIceBarPresented = await appState.navigationState.isIceBarPresented
        let isSearchPresented = await appState.navigationState.isSearchPresented
        let isSettingsPresented = await appState.navigationState.isSettingsPresented

        var sectionsNeedingDisplay = [MenuBarSection.Name]()

        if isSettingsPresented || isSearchPresented {
            sectionsNeedingDisplay = MenuBarSection.Name.allCases
        } else if
            isIceBarPresented,
            let section = await appState.menuBarManager.iceBarPanel.currentSection
        {
            sectionsNeedingDisplay.append(section)
        }

        await updateCache(sections: sectionsNeedingDisplay)
    }

    // MARK: Cache Failed

    /// Returns a Boolean value that indicates whether caching menu bar items
    /// failed for the given section.
    @MainActor
    func cacheFailed(for section: MenuBarSection.Name) -> Bool {
        guard ScreenCapture.cachedCheckPermissions() else {
            return true
        }
        let items = appState?.itemManager.itemCache[section] ?? []
        guard !items.isEmpty else {
            return false
        }
        let keys = Set(images.keys)
        for item in items where keys.contains(item.tag) {
            return false
        }
        return true
    }
}
