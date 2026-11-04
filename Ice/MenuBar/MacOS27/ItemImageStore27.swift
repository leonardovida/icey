//
//  ItemImageStore27.swift
//  Ice
//

import AppKit
import OSLog
import ScreenCaptureKit

/// Images of menu bar items on macOS 27, captured from the active menu bar.
///
/// MenuBarAgent draws every item into one menu bar, so Ice's per-item window captures
/// are gone. Only a capture of the display holds the glyphs (measured on macOS 27.0: a
/// capture of MenuBarAgent's bar window holds just the application menu), and it
/// includes the bar's background. That background is cut away, leaving the glyph on
/// transparency, so the Ice Bar and the layout window draw every item on their own
/// colour whatever is behind the menu bar. Items on an inactive bar are drawn dimmer, so
/// only the active bar is captured. Images are kept on disk, so an item that is concealed
/// still has one.
@available(macOS 27.0, *)
@MainActor
final class ItemImageStore27 {
    typealias CapturedImage = MenuBarItemImageCache.CapturedImage

    private struct IndexEntry: Codable {
        let fileName: String
        let scale: CGFloat
    }

    /// Bumped when stored images change shape. Version 1 kept the menu bar behind the
    /// glyph; version 2 cut it away but left the glyph in the colour it was captured in;
    /// version 3 kept the bar's own uneven padding around it; versions 4 and 5 left a haze
    /// of the bar over the tile, which showed as a pale box behind the glyph; version 6
    /// spaced the glyphs more tightly than the menu bar does; version 7 could not give a
    /// glyph its full margin when the capture ended right at the glyph's edge; version 8
    /// could store a tile cut while the bar was re-laying out.
    private static let storeVersion = "9"

    /// The margin left on each side of a glyph, in points, so items are spaced evenly and
    /// with the menu bar's own rhythm: its glyphs sit 18 to 29 points apart, median 22
    /// (measured on macOS 27.0), which is twice this margin.
    private nonisolated static let glyphMargin: CGFloat = 11

    private let logger = Logger(category: "ItemImageStore27")
    private let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Ice/ItemImages", isDirectory: true)
    private var index = [String: IndexEntry]()
    private var loaded = [String: CapturedImage]()
    private var photoSchedule = PhotoSchedule27()

    /// The capture under way, so captures follow one another instead of overlapping.
    private var captureTask: Task<Void, Never>?

    /// Counts the captures started, so only the last one clears ``captureTask``.
    private var captureGeneration = 0

    /// When the last capture finished, so a fresh one is not taken of an unchanged bar.
    private var lastCaptureFinishedAt: ContinuousClock.Instant?

    /// How long the images just captured stand before the bar is worth capturing again.
    private static let captureFreshness = Duration.milliseconds(700)

    private var appearanceObserver: NSObjectProtocol?

    init() {
        let versionFile = directory.appendingPathComponent("version.txt")
        guard (try? String(contentsOf: versionFile, encoding: .utf8)) == Self.storeVersion else {
            try? FileManager.default.removeItem(at: directory)
            return
        }
        if
            let data = try? Data(contentsOf: directory.appendingPathComponent("index.json")),
            let stored = try? JSONDecoder().decode([String: IndexEntry].self, from: data)
        {
            index = stored
        }
        // Glyphs are stored in the colour that suits the current appearance, so a switch
        // between light and dark needs them captured again.
        appearanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: DistributedNotificationCenter.interfaceThemeChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.discardImages()
            }
        }
    }

    /// Counts the times every image was dropped, so glyphs cut before a drop are not stored.
    private var discardCount = 0

    /// Drops every stored image, so they are captured again.
    private func discardImages() {
        discardCount += 1
        loaded.removeAll()
        index.removeAll()
        photoSchedule = PhotoSchedule27()
        let directory = directory
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// The stored image of the given item, if there is one.
    func image(for item: MenuBarItem) -> CapturedImage? {
        let key = item.tag.description
        if let image = loaded[key] {
            return image
        }
        guard
            let entry = index[key],
            let source = CGImageSourceCreateWithURL(directory.appendingPathComponent(entry.fileName) as CFURL, nil),
            let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return nil
        }
        guard Self.isUsable(cgImage, key: key) else {
            // Stored before this check existed, or stored against a wallpaper that defeated it.
            // Forgetting it is what lets `photographMissing` take the item again.
            index[key] = nil
            let fileName = entry.fileName
            let directory = directory
            Task.detached(priority: .utility) {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(fileName))
            }
            writeIndex()
            return nil
        }
        let image = CapturedImage(cgImage: cgImage, scale: entry.scale)
        loaded[key] = image
        return image
    }

    /// Captures the active menu bar and stores the images of the items drawn on it.
    /// Captures follow one another rather than overlapping: a single reveal set four of them
    /// going at once, 260–290 ms each (measured 2026-09-16), all asking the display server
    /// for the same strip while MenuBarAgent was animating the bar.
    func captureActiveMenuBar(appState: AppState, force: Bool = false) async {
        if !force {
            // A capture already under way photographs the same bar this caller wants.
            if let captureTask {
                await captureTask.value
                return
            }
            // And one that has just been taken still describes it.
            if let last = lastCaptureFinishedAt, ContinuousClock.now - last < Self.captureFreshness {
                return
            }
        }
        captureGeneration += 1
        let generation = captureGeneration
        let previous = captureTask
        let task = Task { [weak self] in
            await previous?.value
            await self?.performCapture(appState: appState)
        }
        captureTask = task
        await task.value
        if captureGeneration == generation {
            captureTask = nil
        }
    }

    private func performCapture(appState: AppState) async {
        // The bar animates for about 250 ms after concealment changes. A capture taken then
        // photographs items in mid-slide, which are thrown away as unsettled anyway, and adds
        // its own load at the moment the animation can least afford it.
        if let remaining = appState.concealer27.timeUntilSettled() {
            try? await Task.sleep(for: remaining)
        }
        let started = ProcessInfo.processInfo.systemUptime
        logger.debug("Menu bar capture: started")
        defer {
            lastCaptureFinishedAt = .now
            logger.debug("Menu bar capture: took \((ProcessInfo.processInfo.systemUptime - started) * 1000, privacy: .public) ms")
        }
        guard
            ScreenCapture.cachedCheckPermissions(),
            let displayID = Bridging.getActiveMenuBarDisplayID(),
            let screen = NSScreen.screens.first(where: { $0.displayID == displayID })
        else {
            return
        }
        let displayBounds = CGDisplayBounds(displayID)
        let barHeight = max(screen.frame.maxY - screen.visibleFrame.maxY, 22)
        let stripFrame = CGRect(x: displayBounds.minX, y: displayBounds.minY, width: displayBounds.width, height: barHeight)
        let items = await MenuBarItemProvider27.items()
        let concealedPIDs = appState.concealer27.concealedPIDs
        guard let captured = await captureStrip(displayID: displayID, size: stripFrame.size) else {
            return
        }
        let (strip, scale) = captured
        // Only items that sat still through the capture are stored. See `settledTags`.
        func frames(_ items: [MenuBarItem]) -> [String: CGRect] {
            Dictionary(items.map { ($0.tag.description, $0.bounds) }, uniquingKeysWith: { first, _ in first })
        }
        let settled = ItemImages27.settledTags(before: frames(items), after: frames(await MenuBarItemProvider27.items()))
        var skipped = 0
        var tiles = [(key: String, rect: CGRect)]()
        for item in items where item.isOnScreen && !item.isControlItem && !concealedPIDs.contains(item.ownerPID) {
            guard settled.contains(item.tag.description) else {
                skipped += 1
                continue
            }
            guard let rect = ItemImages27.cropRect(itemFrame: item.bounds, stripFrame: stripFrame, scale: scale) else {
                continue
            }
            tiles.append((item.tag.description, rect))
        }
        // Cutting the glyphs out is pure pixel work, a few milliseconds a tile, so it runs off the
        // main thread: there it held up the panels, and on macOS 27 every click on the Mac waits
        // for the main thread while the click tap runs. The colour is read here, as AppKit wants.
        let colour = Self.glyphColor()
        let discardsBefore = discardCount
        let glyphs = await Task.detached(priority: .userInitiated) {
            Self.cutGlyphs(from: strip, tiles: tiles, scale: scale, colour: colour)
        }.value
        // The appearance changed while the glyphs were cut, so they have the old colour.
        guard discardCount == discardsBefore else {
            return
        }
        for glyph in glyphs {
            store(glyph, scale: scale)
        }
        writeIndex()
        logger.debug("Stored \(glyphs.count, privacy: .public) item images from display \(displayID, privacy: .public), skipped \(skipped, privacy: .public) that moved")
    }

    /// A glyph cut from a capture, with its PNG encoding, ready to store.
    ///
    /// `@unchecked Sendable` so it can come back from the task that cut it: a `CGImage` is
    /// immutable once made.
    private struct CutGlyph: @unchecked Sendable {
        let key: String
        let image: CGImage
        let png: Data?
    }

    /// Cuts every tile out of a capture of the bar and keeps the usable glyphs. Runs off the main
    /// thread.
    private nonisolated static func cutGlyphs(
        from strip: CGImage,
        tiles: [(key: String, rect: CGRect)],
        scale: CGFloat,
        colour: (r: UInt8, g: UInt8, b: UInt8)
    ) -> [CutGlyph] {
        let crops = tiles.compactMap { tile in
            strip.cropping(to: tile.rect).map { (key: tile.key, image: $0) }
        }
        // MenuBarAgent draws every glyph on a bar in one colour, white or black. Deciding which
        // for the whole strip, rather than tile by tile, keeps a dark patch of wallpaper behind
        // one item from passing for its glyph (see `ItemImages27.toneVotes`).
        var votes = (light: 0, dark: 0)
        for crop in crops {
            guard let pixels = pixels(of: crop.image) else {
                continue
            }
            let tileVotes = ItemImages27.toneVotes(pixels: pixels, width: crop.image.width, height: crop.image.height)
            votes.light += tileVotes.light
            votes.dark += tileVotes.dark
        }
        let tone: ItemImages27.GlyphTone? = votes.light + votes.dark == 0 ? nil : (votes.light >= votes.dark ? .light : .dark)
        return crops.compactMap { crop in
            guard
                let glyph = withoutBackground(crop.image, scale: scale, tone: tone, colour: colour),
                isUsable(glyph, key: crop.key)
            else {
                return nil
            }
            return CutGlyph(key: crop.key, image: glyph, png: pngData(of: glyph))
        }
    }

    /// The image encoded as PNG, with ImageIO, which may be used off the main thread.
    private nonisolated static func pngData(of image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// Shows the applications of items that have no image for a moment, and captures them.
    func photographMissing(items: [MenuBarItem], appState: AppState) async {
        let now = ProcessInfo.processInfo.systemUptime
        let bundleIDs = Set(items.compactMap { item -> String? in
            guard !item.isControlItem, image(for: item) == nil else {
                return nil
            }
            return item.sourceApplication?.bundleIdentifier
        })
        .filter { photoSchedule.mayPhotograph(bundleID: $0, now: now) }
        guard !bundleIDs.isEmpty else {
            return
        }
        // One application at a time, waiting for each capture before revealing the next.
        // Revealed together (measured 2026-09-17) thirteen items no longer fitted the narrow
        // built-in bar and macOS folded nine of them into its own overflow, where they cannot
        // be photographed at all. Revealed in a burst without waiting, they were caught
        // mid-fade instead: the concealment applies behind them were still landing a second
        // and a half later, long after the capture judged the bar settled.
        for bundleID in bundleIDs.sorted().prefix(Self.photographsPerPass) {
            appState.concealer27.showTemporarily(bundleID: bundleID)
            // A shown item is drawn 0.4–0.6 s after its application is allowed (measured).
            try? await Task.sleep(for: .milliseconds(600))
            // Forced: this capture is the point of having shown the application at all, so it
            // must not be answered by one taken before the item appeared.
            await captureActiveMenuBar(appState: appState, force: true)
            appState.concealer27.endTemporaryShow(bundleID: bundleID)
            // Only an application that came away with an image counts as photographed. One
            // whose tile was refused, or whose item macOS folded away, would otherwise wait
            // out the full ten minutes with no glyph at all in the Ice Bar.
            photoSchedule.recordAttempt(
                bundleID: bundleID,
                now: ProcessInfo.processInfo.systemUptime,
                stored: hasImage(forBundleID: bundleID)
            )
        }
    }

    /// How many applications one pass photographs, so a first run does not spend a minute
    /// revealing items one after another.
    private static let photographsPerPass = 6

    /// Whether any of the application's items has a stored image.
    private func hasImage(forBundleID bundleID: String) -> Bool {
        index.keys.contains { $0.hasPrefix(bundleID + ":") }
    }

    // MARK: Private

    private func captureStrip(displayID: CGDirectDisplayID, size: CGSize) async -> (CGImage, CGFloat)? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                return nil
            }
            // Ice's own windows are left out of the capture. The camera and microphone indicator
            // is drawn beside the items, so without this it was photographed as if it were one of
            // them: two of the Ice Bar's tiles came back as an orange microphone.
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let ownWindows = content.windows.filter { $0.owningApplication?.processID == ownPID }
            let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
            let scale = CGFloat(filter.pointPixelScale)
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = CGRect(origin: .zero, size: size)
            configuration.width = Int(size.width * scale)
            configuration.height = Int(size.height * scale)
            configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            return (image, scale)
        } catch {
            logger.error("Could not capture the menu bar: \(error, privacy: .public)")
            return nil
        }
    }

    /// The colour glyphs are drawn in, which is the readable one on the flat background
    /// the Ice Bar and the layout window use.
    private static func glyphColor() -> (r: UInt8, g: UInt8, b: UInt8) {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark ? (255, 255, 255) : (0, 0, 0)
    }

    /// The image's pixels, four bytes each, as the image rules expect them.
    private nonisolated static func pixels(of image: CGImage) -> [UInt8]? {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return drawn ? data : nil
    }

    /// The image with the menu bar behind the glyph made transparent, the glyph recoloured
    /// for the panel, and the bar's own padding replaced by an even margin.
    private nonisolated static func withoutBackground(
        _ image: CGImage,
        scale: CGFloat,
        tone: ItemImages27.GlyphTone?,
        colour: (r: UInt8, g: UInt8, b: UInt8)
    ) -> CGImage? {
        let width = image.width
        let height = image.height
        let count = width * height * 4
        let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        defer { bytes.deallocate() }
        bytes.initialize(repeating: 0, count: count)
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = Array(UnsafeBufferPointer(start: bytes, count: count))
        let background = ItemImages27.backgroundColor(pixels: pixels, width: width, height: height)
        let removed = ItemImages27.removingBackground(pixels: pixels, width: width, height: height, background: background, tone: tone)
        // An item caught mid-fade cannot be rescued by any background estimate: what is left
        // is a faint glyph inside a wide haze of bar, and storing it is what made the Ice
        // Bar's icons pale and too wide. Refuse the tile; the item is photographed again
        // later, standing still. This comes before faint marks are dropped, or a faded glyph
        // would be dropped whole and stored as an empty tile.
        if ItemImages27.isFaded(pixels: removed, width: width, height: height) {
            cutLogger.debug("Refusing a tile of an item caught mid-fade")
            return nil
        }
        // Wallpaper detail in the glyph's own colour survives the colour test; marks that
        // never reach solid are dropped whole, so the trim below does not keep them either.
        var keyed = ItemImages27.tinted(
            pixels: ItemImages27.droppingFaintMarks(pixels: removed, width: width, height: height),
            colour: colour
        )
        // The bitmap holds premultiplied colours, so each channel follows the new opacity.
        for index in stride(from: 0, to: count, by: 4) {
            let opacity = Double(keyed[index + 3]) / 255
            for channel in 0..<3 {
                keyed[index + channel] = UInt8((Double(keyed[index + channel]) * opacity).rounded())
            }
        }
        // Copying from a shorter array would read past its end.
        let isCopied = keyed.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress, buffer.count >= count else {
                return false
            }
            bytes.update(from: baseAddress, count: count)
            return true
        }
        guard isCopied else {
            return nil
        }
        guard
            let keyedImage = context.makeImage(),
            let columns = ItemImages27.glyphColumns(pixels: keyed, width: width, height: height)
        else {
            // Nothing was drawn in the item's rectangle; there is no image to keep.
            return nil
        }
        // The glyph is drawn into a fresh tile rather than cropped with margins, because a
        // capture often ends right at the glyph's edge and then cropping has no room left.
        let margin = Int((Self.glyphMargin * scale).rounded())
        let glyphWidth = columns.upperBound - columns.lowerBound + 1
        let paddedWidth = glyphWidth + margin * 2
        guard
            let glyph = keyedImage.cropping(to: CGRect(x: columns.lowerBound, y: 0, width: glyphWidth, height: height)),
            let padded = CGContext(
                data: nil,
                width: paddedWidth,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: paddedWidth * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo
            )
        else {
            return keyedImage
        }
        padded.draw(glyph, in: CGRect(x: margin, y: 0, width: glyphWidth, height: height))
        return padded.makeImage() ?? keyedImage
    }

    /// Whether a finished tile is a glyph on transparency rather than a piece of the bar.
    ///
    /// Checked both when a tile is stored and when a stored one is first read back. A tile that
    /// kept the bar used to stay for good: `photographMissing` only photographs items with no
    /// image at all, so nothing ever replaced it, and on a notched Mac opening the layout window
    /// does not help either — macOS folds most items away and they cannot be photographed there.
    /// Three such tiles stood for a week on @jasonsmithio's machine (jordanbaird/Ice#995).
    private nonisolated static func isUsable(_ image: CGImage, key: String) -> Bool {
        guard let pixels = pixels(of: image) else {
            return true
        }
        guard ItemImages27.keepsTheBar(pixels: pixels, width: image.width, height: image.height) else {
            return true
        }
        cutLogger.notice("Refusing a tile of \(key, privacy: .public): the bar is still behind the glyph")
        return false
    }

    /// The logger for the work that runs off the main thread, under the same category.
    private nonisolated static let cutLogger = Logger(category: "ItemImageStore27")

    /// Keeps a glyph that ``cutGlyphs(from:tiles:scale:colour:)`` found usable.
    private func store(_ glyph: CutGlyph, scale: CGFloat) {
        let key = glyph.key
        let fileName = ItemImages27.fileName(forTag: key)
        loaded[key] = CapturedImage(cgImage: glyph.image, scale: scale)
        index[key] = IndexEntry(fileName: fileName, scale: scale)
        guard let data = glyph.png else {
            return
        }
        let directory = directory
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
        }
    }

    private func writeIndex() {
        guard let data = try? JSONEncoder().encode(index) else {
            return
        }
        let directory = directory
        let version = Self.storeVersion
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: directory.appendingPathComponent("index.json"), options: .atomic)
            try? version.write(to: directory.appendingPathComponent("version.txt"), atomically: true, encoding: .utf8)
        }
    }
}
