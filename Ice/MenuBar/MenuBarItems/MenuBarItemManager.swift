//
//  MenuBarItemManager.swift
//  Ice
//

import Cocoa
import Combine
import OSLog
import Semaphore

/// Manager for menu bar items.
@MainActor
final class MenuBarItemManager: ObservableObject {
    /// The current cache of menu bar items.
    @Published private(set) var itemCache = ItemCache(displayID: nil)

    /// A Boolean value that indicates whether the most recent cache found
    /// no control item for the hidden section in the menu bar.
    ///
    /// Without that divider, items can't be sorted into sections, so the
    /// cache stays empty. This happens when macOS has turned Icey's items
    /// off, for example in System Settings > Menu Bar.
    @Published private(set) var isHiddenControlItemMissing = false

    /// Logger for the menu bar item manager.
    private nonisolated let logger = Logger.menuBarItemManager

    /// Semaphore to prevent overlapping event operations.
    private nonisolated let eventSemaphore = AsyncSemaphore(value: 1)

    /// Actor for managing menu bar item cache operations.
    private let cacheActor = CacheActor()

    /// Contexts for temporarily shown menu bar items.
    private var temporarilyShownItemContexts = [TemporarilyShownItemContext]()

    /// A timer for rehiding temporarily shown menu bar items.
    private var rehideTimer: Timer?

    /// Timestamp of the most recent menu bar item move operation.
    private var lastMoveOperationTimestamp: ContinuousClock.Instant?

    /// Cached timeouts for move operations.
    private var moveOperationTimeouts = [MenuBarItemTag: Duration]()

    /// The number of moves of temporarily shown items into or out of view
    /// that are in progress.
    ///
    /// An item can be out of place before its context is recorded, and after
    /// its context is taken to move it back, which saving the control item
    /// positions must know about.
    private var temporaryMovesInProgress = 0

    /// The windows of the hidden and always-hidden control items, as found
    /// by the most recent cache.
    private var controlItemWindowIDs: (hidden: CGWindowID, alwaysHidden: CGWindowID?)?

    /// The menu bar items Icey has seen, loaded from the defaults on first use.
    private var knownItems: KnownItems?

    /// New menu bar items waiting to be moved to the section chosen for them.
    private var pendingNewItems = [MenuBarItem]()

    /// The task that moves new menu bar items, while it runs.
    private var newItemPlacementTask: Task<Void, Never>?

    /// The number of cache updates that have put off remembering the
    /// items for the first time, as some items' apps were not yet known.
    private var knownItemsSeedDeferrals = 0

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// The shared app state.
    private(set) weak var appState: AppState?

    /// Sets up the manager.
    func performSetup(with appState: AppState) async {
        self.appState = appState
        await cacheItemsRegardless()
        configureCancellables(with: appState)
    }

    /// Configures the internal observers for the manager.
    private func configureCancellables(with appState: AppState) {
        var c = Set<AnyCancellable>()

        NSWorkspace.shared.publisher(for: \.runningApplications)
            .delay(for: 0.25, scheduler: DispatchQueue.main)
            .discardMerge(Timer.publish(every: 5, tolerance: 1, on: .main, in: .default).autoconnect())
            .debounce(for: 1, scheduler: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else {
                    return
                }
                Task {
                    await self.cacheItemsIfNeeded()
                }
            }
            .store(in: &c)

        appState.navigationState.$settingsNavigationIdentifier
            .sink { [weak self] identifier in
                guard let self, identifier == .menuBarLayout else {
                    return
                }
                Task {
                    await self.cacheItemsRegardless()
                }
            }
            .store(in: &c)

        if #available(macOS 27.0, *) {
            // Accessibility reports frames only for the active menu bar, so read the
            // items again soon after it moves to another display.
            NSWorkspace.shared.notificationCenter
                .publisher(for: NSWorkspace.didActivateApplicationNotification)
                // The menu bar takes about a second to move (measured).
                .debounce(for: 1.5, scheduler: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self else {
                        return
                    }
                    Task {
                        await self.cacheItemsIfNeeded()
                    }
                }
                .store(in: &c)
        }

        cancellables = c
    }

    /// Returns a Boolean value that indicates whether the most recent
    /// menu bar item move operation occurred within the given duration.
    func lastMoveOperationOccurred(within duration: Duration) -> Bool {
        guard let timestamp = lastMoveOperationTimestamp else {
            return false
        }
        return timestamp.duration(to: .now) <= duration
    }
}

// MARK: - Item Cache

extension MenuBarItemManager {
    /// An actor that manages menu bar item cache operations.
    private final actor CacheActor {
        /// Stored task for the current cache operation.
        private var cacheTask: Task<Void, Never>?

        /// A list of the menu bar item window identifiers at the time
        /// of the previous cache.
        private(set) var cachedItemWindowIDs = [CGWindowID]()

        /// Runs the given async closure as a task and waits for it to
        /// complete before returning.
        ///
        /// If a task from a previous call to this method is currently
        /// running, that task is cancelled and replaced.
        func runCacheTask(_ operation: @escaping () async -> Void) async {
            cacheTask.take()?.cancel()
            let task = Task(operation: operation)
            cacheTask = task
            await task.value
        }

        /// Updates the list of cached menu bar item window identifiers.
        func updateCachedItemWindowIDs(_ itemWindowIDs: [CGWindowID]) {
            cachedItemWindowIDs = itemWindowIDs
        }

        /// Clears the list of cached menu bar item window identifiers.
        func clearCachedItemWindowIDs() {
            cachedItemWindowIDs.removeAll()
        }
    }

    /// Cache for menu bar items.
    struct ItemCache: Hashable {
        /// Storage for cached menu bar items, keyed by section.
        private var storage = [MenuBarSection.Name: [MenuBarItem]]()

        /// The identifier of the display with the active menu bar at
        /// the time this cache was created.
        let displayID: CGDirectDisplayID?

        /// The cached menu bar items as an array.
        var managedItems: [MenuBarItem] {
            MenuBarSection.Name.allCases.reduce(into: []) { result, section in
                guard let items = storage[section] else {
                    return
                }
                result.append(contentsOf: items)
            }
        }

        /// Creates a cache with the given display identifier.
        init(displayID: CGDirectDisplayID?) {
            self.displayID = displayID
        }

        // TODO: This is redundant now, so remove it.
        /// Returns the managed menu bar items for the given section.
        func managedItems(for section: MenuBarSection.Name) -> [MenuBarItem] {
            self[section]
        }

        /// Returns the address for the menu bar item with the given tag,
        /// if it exists in the cache.
        func address(for tag: MenuBarItemTag) -> (section: MenuBarSection.Name, index: Int)? {
            for (section, items) in storage {
                guard let index = items.firstIndex(matching: tag) else {
                    continue
                }
                return (section, index)
            }
            return nil
        }

        /// Returns the address of the given menu bar item, if it exists
        /// in the cache.
        ///
        /// Several items of one app can share a tag, so the item's window
        /// is looked for first.
        func address(of item: MenuBarItem) -> (section: MenuBarSection.Name, index: Int)? {
            for (section, items) in storage {
                guard let index = items.firstIndex(where: { $0.windowID == item.windowID }) else {
                    continue
                }
                return (section, index)
            }
            return address(for: item.tag)
        }

        /// Inserts the given menu bar item into the cache at the specified
        /// destination.
        mutating func insert(_ item: MenuBarItem, at destination: MoveDestination) {
            let targetTag = destination.targetItem.tag

            if targetTag == .hiddenControlItem {
                switch destination {
                case .leftOfItem:
                    self[.hidden].append(item)
                case .rightOfItem:
                    self[.visible].insert(item, at: 0)
                }
                return
            }

            if targetTag == .alwaysHiddenControlItem {
                switch destination {
                case .leftOfItem:
                    self[.alwaysHidden].append(item)
                case .rightOfItem:
                    self[.hidden].insert(item, at: 0)
                }
                return
            }

            guard case (let section, var index)? = address(of: destination.targetItem) else {
                return
            }

            if case .rightOfItem = destination {
                let range = self[section].startIndex...self[section].endIndex
                index = (index + 1).clamped(to: range)
            }

            self[section].insert(item, at: index)
        }

        /// Accesses the items in the given section.
        subscript(section: MenuBarSection.Name) -> [MenuBarItem] {
            get { storage[section, default: []] }
            set { storage[section] = newValue }
        }
    }

    /// A pair of control items, taken from a list of menu bar items
    /// during a menu bar item cache operation.
    private struct ControlItemPair {
        let hidden: MenuBarItem
        let alwaysHidden: MenuBarItem?

        init?(items: inout [MenuBarItem]) {
            guard let hidden = items.removeFirst(matching: .hiddenControlItem) else {
                return nil
            }
            self.hidden = hidden
            self.alwaysHidden = items.removeFirst(matching: .alwaysHiddenControlItem)
        }
    }

    /// Context maintained during a menu bar item cache operation.
    private struct CacheContext {
        let controlItems: ControlItemPair

        var cache: ItemCache
        var temporarilyShownItems = [(MenuBarItem, MoveDestination)]()
        var shouldClearCachedItemWindowIDs = false

        private(set) lazy var hiddenControlItemBounds = bestBounds(for: controlItems.hidden)
        private(set) lazy var alwaysHiddenControlItemBounds = controlItems.alwaysHidden.map(bestBounds)

        init(controlItems: ControlItemPair, displayID: CGDirectDisplayID?) {
            self.controlItems = controlItems
            self.cache = ItemCache(displayID: displayID)
        }

        func bestBounds(for item: MenuBarItem) -> CGRect {
            Bridging.getWindowBounds(for: item.windowID) ?? item.bounds
        }

        func isValidForCaching(_ item: MenuBarItem) -> Bool {
            if !item.canBeHidden {
                return false
            }
            if item.isSystemClone {
                return false
            }
            if item.isControlItem, item.tag != .visibleControlItem {
                return false
            }
            return true
        }

        /// Returns the section the given item is in.
        ///
        /// Window bounds carry sub-point values on a scaled display, so an
        /// item flush against a control item can overlap it by a fraction of
        /// a point. Compared exactly, that item was in no section and was
        /// left out of the cache, so it was missing from the Menu Bar Layout
        /// pane and the Ice Bar while it showed in the menu bar
        /// (jordanbaird/Ice#655). The edges are compared with the same
        /// tolerance as moves, which is far narrower than any item.
        mutating func findSection(for item: MenuBarItem) -> MenuBarSection.Name? {
            lazy var itemBounds = bestBounds(for: item)
            let tolerance = MenuBarItemManager.positionTolerance
            return MenuBarSection.Name.allCases.first { section in
                switch section {
                case .visible:
                    return itemBounds.minX >= hiddenControlItemBounds.maxX - tolerance
                case .hidden:
                    if let alwaysHiddenControlItemBounds {
                        return itemBounds.maxX <= hiddenControlItemBounds.minX + tolerance &&
                        itemBounds.minX >= alwaysHiddenControlItemBounds.maxX - tolerance
                    } else {
                        return itemBounds.maxX <= hiddenControlItemBounds.minX + tolerance
                    }
                case .alwaysHidden:
                    if let alwaysHiddenControlItemBounds {
                        return itemBounds.maxX <= alwaysHiddenControlItemBounds.minX + tolerance
                    } else {
                        return false
                    }
                }
            }
        }
    }

    /// Caches the given menu bar items, without ensuring that the provided
    /// control items are correctly ordered.
    private func uncheckedCacheItems(
        items: [MenuBarItem],
        controlItems: ControlItemPair,
        displayID: CGDirectDisplayID?
    ) async {
        var context = CacheContext(controlItems: controlItems, displayID: displayID)
        let windowIDs = Set(items.map { $0.windowID })

        for item in items where context.isValidForCaching(item) {
            if item.sourcePID == nil {
                logger.warning("Missing sourcePID for \(item.logString, privacy: .public)")
                context.shouldClearCachedItemWindowIDs = true
            }

            if let temp = temporarilyShownItemContexts.first(where: { $0.matches(item, windowIDs: windowIDs) }) {
                // Cache temporarily shown items as if they were in their original locations.
                // Keep track of them separately and use their return destinations to insert
                // them into the cache once all other items have been handled.
                context.temporarilyShownItems.append((item, temp.returnDestination))
                continue
            }

            if let section = context.findSection(for: item) {
                context.cache[section].append(item)
                continue
            }

            logger.warning("Couldn't find section for caching \(item.logString, privacy: .public)")
            context.shouldClearCachedItemWindowIDs = true
        }

        for (item, destination) in context.temporarilyShownItems {
            context.cache.insert(item, at: destination)
        }

        if context.shouldClearCachedItemWindowIDs {
            logger.info("Clearing cached menu bar item windowIDs")
            await cacheActor.clearCachedItemWindowIDs() // Ensure next cache isn't skipped.
        }

        guard itemCache != context.cache else {
            logger.debug("Not updating menu bar item cache, as items haven't changed")
            return
        }

        itemCache = context.cache
        logger.debug("Updated menu bar item cache")
    }

    /// Caches the current menu bar items, regardless of whether the
    /// items have changed since the previous cache.
    ///
    /// Before caching, this method ensures that the control items for
    /// the hidden and always-hidden sections are correctly ordered,
    /// arranging them into valid positions if needed.
    func cacheItemsRegardless(_ currentItemWindowIDs: [CGWindowID]? = nil) async {
        await cacheActor.runCacheTask { [weak self] in
            guard let self else {
                return
            }

            guard !lastMoveOperationOccurred(within: .seconds(1)) else {
                logger.debug("Skipping menu bar item cache due to recent item movement")
                return
            }

            let displayID = Bridging.getActiveMenuBarDisplayID()
            var items = await MenuBarItem.getMenuBarItems(option: .activeSpace)

            let itemWindowIDs = currentItemWindowIDs ?? items.reversed().map { $0.windowID }
            await cacheActor.updateCachedItemWindowIDs(itemWindowIDs)

            if #available(macOS 27.0, *), let appState {
                // On macOS 27 the saved layout, not the order on the bar, places items in sections,
                // so Ice's dividers are not needed. Accessibility reports them only on the display
                // Ice launched on, and requiring them emptied the cache on the other display.
                // An upgrade from an earlier macOS arrives with its sections in the bar's order and
                // nowhere else, so the first readable bar is where they come from.
                appState.concealer27.seedLayoutIfNeeded(items: items)
                let cache = appState.concealer27.cacheFromSavedLayout(items: items, displayID: displayID)
                if itemCache != cache {
                    itemCache = cache
                    logger.info(
                        """
                        macOS 27 cache: \
                        visible=\(cache[.visible].map(\.tag.namespace.description).joined(separator: ","), privacy: .public) \
                        hidden=\(cache[.hidden].map(\.tag.namespace.description).joined(separator: ","), privacy: .public) \
                        alwaysHidden=\(cache[.alwaysHidden].map(\.tag.namespace.description).joined(separator: ","), privacy: .public)
                        """
                    )
                }
                return
            }

            guard let controlItems = ControlItemPair(items: &items) else {
                // ???: Is clearing the cache the best thing to do here?
                logger.warning("Missing control item for hidden section, clearing menu bar item cache")
                itemCache = ItemCache(displayID: nil)
                if !isHiddenControlItemMissing {
                    isHiddenControlItemMissing = true
                }
                // The window list was stored above, so `cacheItemsIfNeeded()` would
                // skip every later attempt until some item window came or went,
                // leaving the cache empty for as long as the menu bar stayed the
                // same (jordanbaird/Ice#908 shows a session stuck in this state).
                // Forget it, so the next periodic check tries again.
                await cacheActor.clearCachedItemWindowIDs()
                return
            }
            if isHiddenControlItemMissing {
                isHiddenControlItemMissing = false
            }

            // Moving items is not supported on macOS 27 yet (plan 2), so the dividers
            // stay where macOS placed them.
            if #unavailable(macOS 27.0) {
                await enforceControlItemOrder(controlItems: controlItems, items: items)
            }
            controlItemWindowIDs = (controlItems.hidden.windowID, controlItems.alwaysHidden?.windowID)
            await uncheckedCacheItems(items: items, controlItems: controlItems, displayID: displayID)
            recordNewItems(controlItems: controlItems)
        }
    }

    /// Caches the current menu bar items, if the items have changed
    /// since the previous cache.
    ///
    /// Before caching, this method ensures that the control items for
    /// the hidden and always-hidden sections are correctly ordered,
    /// arranging them into valid positions if needed.
    func cacheItemsIfNeeded() async {
        if #available(macOS 27.0, *) {
            // There is no item window list on macOS 27. A reorder keeps the synthetic
            // identifiers, so the signature also carries each item's position.
            let items = await MenuBarItem.getMenuBarItems(option: .activeSpace)
            // Int(_:) traps on a non-finite value, so a bad frame must not reach it.
            let signature = items.map { $0.windowID &+ UInt32(truncatingIfNeeded: Int(exactly: $0.bounds.minX.rounded(.towardZero)) ?? 0) }
            if await cacheActor.cachedItemWindowIDs != signature {
                await cacheItemsRegardless(signature)
            }
            return
        }
        let itemWindowIDs = Bridging.getMenuBarWindowList(option: [.itemsOnly, .activeSpace])
        if await cacheActor.cachedItemWindowIDs != itemWindowIDs {
            await cacheItemsRegardless(itemWindowIDs)
        }
    }
}

// MARK: - Event Helpers

extension MenuBarItemManager {
    /// An error that can occur during menu bar item event operations.
    enum EventError: CustomStringConvertible, LocalizedError {
        /// A generic indication of a failure.
        case cannotComplete
        /// An event source cannot be created or is otherwise invalid.
        case invalidEventSource
        /// The location of the mouse cannot be found.
        case missingMouseLocation
        /// A failure during the creation of an event.
        case eventCreationFailure(MenuBarItem)
        /// A timeout during an event operation.
        case eventOperationTimeout(MenuBarItem)
        /// A menu bar item is not movable.
        case itemNotMovable(MenuBarItem)
        /// A timeout waiting for a menu bar item to respond to an event.
        case itemResponseTimeout(MenuBarItem)
        /// A menu bar item's bounds cannot be found.
        case missingItemBounds(MenuBarItem)
        /// A menu bar item is not on any display, so it can't be clicked.
        case itemNotOnScreen(MenuBarItem)

        var description: String {
            switch self {
            case .cannotComplete:
                "\(Self.self).cannotComplete"
            case .invalidEventSource:
                "\(Self.self).invalidEventSource"
            case .missingMouseLocation:
                "\(Self.self).missingMouseLocation"
            case .eventCreationFailure(let item):
                "\(Self.self).eventCreationFailure(item: \(item.tag))"
            case .eventOperationTimeout(let item):
                "\(Self.self).eventOperationTimeout(item: \(item.tag))"
            case .itemNotMovable(let item):
                "\(Self.self).itemNotMovable(item: \(item.tag))"
            case .itemResponseTimeout(let item):
                "\(Self.self).itemResponseTimeout(item: \(item.tag))"
            case .missingItemBounds(let item):
                "\(Self.self).missingItemBounds(item: \(item.tag))"
            case .itemNotOnScreen(let item):
                "\(Self.self).itemNotOnScreen(item: \(item.tag))"
            }
        }

        var errorDescription: String? {
            switch self {
            case .cannotComplete:
                "Operation could not be completed"
            case .invalidEventSource:
                "Invalid event source"
            case .missingMouseLocation:
                "Missing mouse location"
            case .eventCreationFailure(let item):
                "Could not create event for \"\(item.displayName)\""
            case .eventOperationTimeout(let item):
                "Event operation timed out for \"\(item.displayName)\""
            case .itemNotMovable(let item):
                "\"\(item.displayName)\" is not movable"
            case .itemResponseTimeout(let item):
                "\"\(item.displayName)\" took too long to respond"
            case .missingItemBounds(let item):
                "Missing bounds rectangle for \"\(item.displayName)\""
            case .itemNotOnScreen(let item):
                "\"\(item.displayName)\" is not on screen"
            }
        }

        var recoverySuggestion: String? {
            switch self {
            case .itemNotMovable:
                return nil
            case .itemResponseTimeout:
                // The item ignored the drag on every attempt. Items macOS shows
                // for an iPhone's Live Activities did so in every report
                // (jordanbaird/Ice#656, #704), so say that some items can't be
                // moved, rather than only asking for a bug report.
                return """
                    The item did not move when Icey dragged it. Some items, such as \
                    the ones macOS shows for iPhone Live Activities, may not allow \
                    being moved. Please try again. If the error persists, please \
                    file a bug report.
                    """
            default:
                return "Please try again. If the error persists, please file a bug report."
            }
        }
    }

    /// Returns a Boolean value that indicates whether the user has
    /// paused input for at least the given duration.
    ///
    /// Caps Lock is a lock, not a key being held, so it does not count
    /// as input. Counting it meant that while Caps Lock was on, Ice
    /// waited for a key release that never came: items clicked in the
    /// Ice Bar or the search panel never opened, and shown items stayed
    /// in view until Caps Lock was turned off.
    ///
    /// - Parameter duration: The duration that certain types of input
    ///   events must not have occured within in order to return `true`.
    private nonisolated func hasUserPausedInput(for duration: Duration) -> Bool {
        NSEvent.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(.capsLock)
            .isEmpty &&
        !MouseHelpers.lastMovementOccurred(within: duration) &&
        !MouseHelpers.lastScrollWheelOccurred(within: duration) &&
        !MouseHelpers.isButtonPressed()
    }

    /// Waits asynchronously for the user to pause input.
    ///
    /// The check is repeated every 10ms. It runs before every move and
    /// click, including those that open a hidden item's menu from the
    /// Ice Bar or the search panel, so a coarser interval delays those
    /// menus by up to the full interval. Each check reads a few event
    /// source counters and costs about 25µs.
    private nonisolated func waitForUserToPauseInput() async throws {
        let waitTask = Task {
            while true {
                try Task.checkCancellation()
                if hasUserPausedInput(for: .milliseconds(50)) {
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        do {
            try await waitTask.value
        } catch {
            throw EventError.cannotComplete
        }
    }

    /// Waits between move operations for a dynamic amount of time,
    /// based on the timestamp of the last move operation.
    private nonisolated func waitForMoveOperationBuffer() async throws {
        if let timestamp = await lastMoveOperationTimestamp {
            let buffer = max(.milliseconds(25) - timestamp.duration(to: .now), .zero)
            logger.debug("Move operation buffer: \(buffer)")
            do {
                try await Task.sleep(for: buffer)
            } catch {
                throw EventError.cannotComplete
            }
        }
    }

    /// Waits for the given duration between event operations.
    ///
    /// Since most event operations must perform cleanup or otherwise
    /// run to completion, this method ignores task cancellation.
    private nonisolated func eventSleep(for duration: Duration = .milliseconds(25)) async {
        let task = Task {
            try? await Task.sleep(for: duration)
        }
        await task.value
    }

    /// Waits for an item that was just moved to stop moving, so that it
    /// is clicked where it ends up.
    ///
    /// The item's bounds are read every 10ms, and the wait ends once
    /// they have not changed for 20ms, which is longer than a frame at
    /// 60Hz, or after `timeout`, which is the fixed delay this replaced.
    /// An item that lands at once is clicked after about 20ms instead
    /// of 100ms.
    ///
    /// Like ``eventSleep(for:)``, this method ignores task cancellation.
    private nonisolated func waitForItemToSettle(
        _ item: MenuBarItem,
        timeout: Duration = .milliseconds(100)
    ) async {
        let interval = Duration.milliseconds(10)
        let requiredStableReads = 2
        let deadline = ContinuousClock.now + timeout
        var previous = Bridging.getWindowBounds(for: item.windowID)
        var stableReads = 0
        while ContinuousClock.now < deadline {
            await eventSleep(for: min(interval, ContinuousClock.now.duration(to: deadline)))
            let current = Bridging.getWindowBounds(for: item.windowID)
            if let current, current == previous {
                stableReads += 1
                if stableReads >= requiredStableReads {
                    return
                }
            } else {
                stableReads = 0
            }
            previous = current
        }
    }

    /// Returns the current bounds for the given item.
    private nonisolated func getCurrentBounds(for item: MenuBarItem) async throws -> CGRect {
        let task = Task.detached(priority: .userInitiated) {
            guard let bounds = Bridging.getWindowBounds(for: item.windowID) else {
                throw EventError.missingItemBounds(item)
            }
            return bounds
        }
        return try await task.value
    }

    /// Returns the current mouse location.
    private nonisolated func getMouseLocation() throws -> CGPoint {
        guard let location = MouseHelpers.locationCoreGraphics else {
            throw EventError.missingMouseLocation
        }
        return location
    }

    /// Returns the process identifier that can be used to create
    /// and post a menu bar item event.
    private nonisolated func getEventPID(for item: MenuBarItem) -> pid_t {
        item.sourcePID ?? item.ownerPID
    }

    /// Returns an event source for a menu bar item event operation.
    private nonisolated func getEventSource(
        with stateID: CGEventSourceStateID = .hidSystemState
    ) throws -> CGEventSource {
        enum Context {
            static var cache = [CGEventSourceStateID: CGEventSource]()
        }
        if let source = Context.cache[stateID] {
            return source
        }
        guard let source = CGEventSource(stateID: stateID) else {
            throw EventError.invalidEventSource
        }
        Context.cache[stateID] = source
        return source
    }

    /// Prevents local events from being suppressed.
    private nonisolated func permitLocalEvents() throws {
        let source = try getEventSource(with: .combinedSessionState)
        let states: [CGEventSuppressionState] = [
            .eventSuppressionStateRemoteMouseDrag,
            .eventSuppressionStateSuppressionInterval,
        ]
        for state in states {
            source.setLocalEventsFilterDuringSuppressionState(.permitAllEvents, state: state)
        }
        source.localEventsSuppressionInterval = 0
    }

    /// A continuation for an event operation that resumes once, from
    /// whichever of an event tap or a cancellation reaches it first.
    ///
    /// The timeout of an event operation cancels the wait, but the wait
    /// only ends when the continuation resumes. If the item never responds,
    /// the timeout's task group would otherwise wait forever, leaving the
    /// event taps enabled and the event semaphore held.
    private final class EventContinuation: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, any Error>?
        private var result: Result<Void, any Error>?

        /// Calls the given closure with the continuation, and waits until
        /// it resumes or the current task is cancelled.
        static func wait(_ body: (EventContinuation) -> Void) async throws {
            let eventContinuation = EventContinuation()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    eventContinuation.set(continuation)
                    body(eventContinuation)
                }
            } onCancel: {
                eventContinuation.resume(throwing: CancellationError())
            }
        }

        /// Sets the continuation to resume, resuming it at once if a
        /// result has already arrived.
        private func set(_ continuation: CheckedContinuation<Void, any Error>) {
            let result: Result<Void, any Error>? = lock.withLock {
                if self.result == nil {
                    self.continuation = continuation
                }
                return self.result
            }
            if let result {
                continuation.resume(with: result)
            }
        }

        /// Resumes the continuation with the given result, unless it has
        /// already been resumed.
        private func resume(with result: Result<Void, any Error>) {
            let continuation: CheckedContinuation<Void, any Error>? = lock.withLock {
                guard self.result == nil else {
                    return nil
                }
                self.result = result
                return self.continuation.take()
            }
            continuation?.resume(with: result)
        }

        /// Resumes the continuation, unless it has already been resumed.
        func resume() {
            resume(with: .success(()))
        }

        /// Resumes the continuation by throwing the given error, unless it
        /// has already been resumed.
        func resume(throwing error: any Error) {
            resume(with: .failure(error))
        }
    }

    /// Posts an event to the given menu bar item and waits until
    /// it is received before returning.
    ///
    /// - Parameters:
    ///   - event: The event to post.
    ///   - item: The menu bar item that the event targets.
    ///   - timeout: The base duration to wait before throwing an error.
    ///     The value of this parameter is multiplied by `count` to
    ///     produce the actual timeout duration.
    ///   - count: The number of times to repeat the operation. As it
    ///     is considerably more efficient, prefer increasing this value
    ///     over repeatedly calling `postEventWithBarrier`.
    private nonisolated func postEventWithBarrier(
        _ event: CGEvent,
        to item: MenuBarItem,
        timeout: Duration,
        repeating count: Int = 1
    ) async throws {
        MouseHelpers.hideCursor()
        defer {
            MouseHelpers.showCursor()
        }

        guard
            let entryEvent = CGEvent.uniqueNullEvent(),
            let exitEvent = CGEvent.uniqueNullEvent()
        else {
            throw EventError.eventCreationFailure(item)
        }

        let pid = getEventPID(for: item)
        event.setTargetPID(pid)

        let firstLocation = EventTap.Location.pid(pid)
        let secondLocation = EventTap.Location.sessionEventTap

        var count = count
        var eventTaps = [EventTap]()

        let timeoutTask = Task(timeout: timeout * count) {
            try await EventContinuation.wait { continuation in
                // Listen for the following events at the first location
                // and perform the following actions:
                //
                // - Entry event: Decrement the count and post the real
                //   event to the second location (handled in EventTap 2).
                // - Exit event: Resume the continuation.
                //
                // These events serve as start (or continue) and stop
                // signals, and are discarded.
                let eventTap1 = EventTap(
                    label: "EventTap 1",
                    type: .null,
                    location: firstLocation,
                    placement: .headInsertEventTap,
                    option: .defaultTap
                ) { tap, rEvent in
                    if rEvent.matches(entryEvent, byIntegerFields: [.eventSourceUserData]) {
                        count -= 1
                        event.post(to: secondLocation)
                        return nil
                    }
                    if rEvent.matches(exitEvent, byIntegerFields: [.eventSourceUserData]) {
                        tap.disable()
                        continuation.resume()
                        return nil
                    }
                    return rEvent
                }

                // Listen for the real event at the second location and,
                // depending on the count, post either the entry or exit
                // event to the first location (handled in EventTap 1).
                let eventTap2 = EventTap(
                    label: "EventTap 2",
                    type: event.type,
                    location: secondLocation,
                    placement: .tailAppendEventTap,
                    option: .listenOnly
                ) { tap, rEvent in
                    guard rEvent.matches(event, byIntegerFields: CGEventField.menuBarItemEventFields) else {
                        return rEvent
                    }
                    if count <= 0 {
                        tap.disable()
                        exitEvent.post(to: firstLocation)
                    } else {
                        entryEvent.post(to: firstLocation)
                    }
                    rEvent.setTargetPID(pid)
                    return rEvent
                }

                // Keep the taps alive.
                eventTaps.append(eventTap1)
                eventTaps.append(eventTap2)

                Task {
                    await withTaskCancellationHandler {
                        eventTap1.enable()
                        eventTap2.enable()
                        entryEvent.post(to: firstLocation)
                    } onCancel: {
                        eventTap1.disable()
                        eventTap2.disable()
                        continuation.resume(throwing: CancellationError())
                    }
                }
            }
        }
        do {
            try await timeoutTask.value
        } catch is TaskTimeoutError {
            throw EventError.eventOperationTimeout(item)
        } catch {
            throw EventError.cannotComplete
        }
    }

    /// Casts forbidden magic to make a menu bar item receive and
    /// respond to an event during a move operation.
    ///
    /// - Parameters:
    ///   - event: The event to post.
    ///   - item: The menu bar item that the event targets.
    ///   - timeout: The base duration to wait before throwing an error.
    ///     The value of this parameter is multiplied by `count` to
    ///     produce the actual timeout duration.
    ///   - count: The number of times to repeat the operation. As it
    ///     is considerably more efficient, prefer increasing this value
    ///     over repeatedly calling `scrombleEvent`.
    private nonisolated func scrombleEvent(
        _ event: CGEvent,
        item: MenuBarItem,
        timeout: Duration,
        repeating count: Int = 1
    ) async throws {
        MouseHelpers.hideCursor()
        defer {
            MouseHelpers.showCursor()
        }

        guard
            let entryEvent = CGEvent.uniqueNullEvent(),
            let exitEvent = CGEvent.uniqueNullEvent()
        else {
            throw EventError.eventCreationFailure(item)
        }

        let pid = getEventPID(for: item)
        event.setTargetPID(pid)

        let firstLocation = EventTap.Location.pid(pid)
        let secondLocation = EventTap.Location.sessionEventTap

        var count = count
        var eventTaps = [EventTap]()

        let timeoutTask = Task(timeout: timeout * count) {
            try await EventContinuation.wait { continuation in
                // Listen for the following events at the first location
                // and perform the following actions:
                //
                // - Entry event: Decrement the count and post the real
                //   event to the second location (handled in EventTap 2).
                // - Exit event: Resume the continuation.
                //
                // These events serve as start (or continue) and stop
                // signals, and are discarded.
                let eventTap1 = EventTap(
                    label: "EventTap 1",
                    type: .null,
                    location: firstLocation,
                    placement: .headInsertEventTap,
                    option: .defaultTap
                ) { tap, rEvent in
                    if rEvent.matches(entryEvent, byIntegerFields: [.eventSourceUserData]) {
                        count -= 1
                        event.post(to: secondLocation)
                        return nil
                    }
                    if rEvent.matches(exitEvent, byIntegerFields: [.eventSourceUserData]) {
                        tap.disable()
                        continuation.resume()
                        return nil
                    }
                    return rEvent
                }

                // Listen for the real event at the second location and
                // post the real event to the first location (handled in
                // EventTap 3).
                let eventTap2 = EventTap(
                    label: "EventTap 2",
                    type: event.type,
                    location: secondLocation,
                    placement: .tailAppendEventTap,
                    option: .listenOnly
                ) { tap, rEvent in
                    guard rEvent.matches(event, byIntegerFields: CGEventField.menuBarItemEventFields) else {
                        return rEvent
                    }
                    if count <= 0 {
                        tap.disable()
                    }
                    event.post(to: firstLocation)
                    rEvent.setTargetPID(pid)
                    return rEvent
                }

                // Listen for the real event at the first location and,
                // depending on the count, post either the entry or exit
                // event to the first location (handled in EventTap 1).
                let eventTap3 = EventTap(
                    label: "EventTap 3",
                    type: event.type,
                    location: firstLocation,
                    placement: .headInsertEventTap,
                    option: .listenOnly
                ) { tap, rEvent in
                    guard rEvent.matches(event, byIntegerFields: CGEventField.menuBarItemEventFields) else {
                        return rEvent
                    }
                    if count <= 0 {
                        tap.disable()
                        exitEvent.post(to: firstLocation)
                    } else {
                        entryEvent.post(to: firstLocation)
                    }
                    rEvent.setTargetPID(pid)
                    return rEvent
                }

                // Keep the taps alive.
                eventTaps.append(eventTap1)
                eventTaps.append(eventTap2)
                eventTaps.append(eventTap3)

                Task {
                    await withTaskCancellationHandler {
                        eventTap1.enable()
                        eventTap2.enable()
                        eventTap3.enable()
                        entryEvent.post(to: firstLocation)
                    } onCancel: {
                        eventTap1.disable()
                        eventTap2.disable()
                        eventTap3.disable()
                        continuation.resume(throwing: CancellationError())
                    }
                }
            }
        }
        do {
            try await timeoutTask.value
        } catch is TaskTimeoutError {
            throw EventError.eventOperationTimeout(item)
        } catch {
            throw EventError.cannotComplete
        }
    }
}

// MARK: - Moving Items

extension MenuBarItemManager {
    /// Destinations for menu bar item move operations.
    enum MoveDestination {
        /// The destination to the left of the given target item.
        case leftOfItem(MenuBarItem)
        /// The destination to the right of the given target item.
        case rightOfItem(MenuBarItem)

        /// The destination's target item.
        var targetItem: MenuBarItem {
            switch self {
            case .leftOfItem(let item), .rightOfItem(let item): item
            }
        }

        /// A string to use for logging purposes.
        var logString: String {
            switch self {
            case .leftOfItem(let item): "left of \(item.logString)"
            case .rightOfItem(let item): "right of \(item.logString)"
            }
        }
    }

    /// Returns the default timeout for move operations associated
    /// with the given item.
    private func getDefaultMoveOperationTimeout(for item: MenuBarItem) -> Duration {
        if item.isBentoBox {
            // Bento Boxes (i.e. Control Center groups) generally
            // take a little longer to respond.
            return .milliseconds(100)
        }
        return .milliseconds(50)
    }

    /// Returns the cached timeout for move operations associated
    /// with the given item.
    private func getMoveOperationTimeout(for item: MenuBarItem) -> Duration {
        if let timeout = moveOperationTimeouts[item.tag] {
            return timeout
        }
        return getDefaultMoveOperationTimeout(for: item)
    }

    /// Updates the cached timeout for move operations associated
    /// with the given item.
    private func updateMoveOperationTimeout(_ timeout: Duration, for item: MenuBarItem) {
        let current = getMoveOperationTimeout(for: item)
        let average = (timeout + current) / 2
        let clamped = average.clamped(min: .milliseconds(25), max: .milliseconds(150))
        moveOperationTimeouts[item.tag] = clamped
    }

    /// Returns the target points for creating the events needed to
    /// move a menu bar item to the given destination.
    private nonisolated func getTargetPoints(
        forMoving item: MenuBarItem,
        to destination: MoveDestination
    ) async throws -> (start: CGPoint, end: CGPoint) {
        let itemBounds = try await getCurrentBounds(for: item)
        let targetBounds = try await getCurrentBounds(for: destination.targetItem)
        switch destination {
        case .leftOfItem:
            var start = CGPoint(x: targetBounds.minX, y: targetBounds.minY)
            var end = start
            if itemBounds.maxX <= targetBounds.minX {
                // Direction of movement: ->
                end.x -= itemBounds.width
            } else {
                // Direction of movement: <-
                start.x -= 1
            }
            return (start, end)
        case .rightOfItem:
            var start = CGPoint(x: targetBounds.maxX, y: targetBounds.minY)
            var end = start
            if itemBounds.minX <= targetBounds.maxX {
                // Direction of movement: ->
                end.x -= itemBounds.width
            } else {
                // Direction of movement: <-
                start.x += 1
            }
            return (start, end)
        }
    }

    /// The tolerance used when checking whether an item has reached its
    /// destination.
    ///
    /// Window bounds come from the window server and carry sub-point values on a
    /// scaled display, so two items that are visually flush can report edges that
    /// differ by a fraction. Comparing them exactly made a move that had in fact
    /// succeeded look like a failure, sending it around the retry loop again — up
    /// to `maxAttempts` times, each with its own wait. A tolerance well under the
    /// width of the narrowest menu bar item cannot accept a wrong position.
    private nonisolated static let positionTolerance: CGFloat = 2

    /// Returns a Boolean value that indicates whether the given menu bar
    /// item has the correct position, relative to the given destination.
    private nonisolated func itemHasCorrectPosition(
        item: MenuBarItem,
        for destination: MoveDestination
    ) async throws -> Bool {
        let itemBounds = try await getCurrentBounds(for: item)
        let targetBounds = try await getCurrentBounds(for: destination.targetItem)
        let tolerance = Self.positionTolerance
        return switch destination {
        case .leftOfItem: abs(itemBounds.maxX - targetBounds.minX) <= tolerance
        case .rightOfItem: abs(itemBounds.minX - targetBounds.maxX) <= tolerance
        }
    }

    /// Waits for a menu bar item to respond to a series of previously
    /// posted move events.
    ///
    /// - Parameters:
    ///   - item: The item to check for a response.
    ///   - initialOrigin: The origin of the item before the events were posted.
    ///   - timeout: The duration to wait before throwing an error.
    private nonisolated func waitForMoveEventResponse(
        from item: MenuBarItem,
        initialOrigin: CGPoint,
        timeout: Duration
    ) async throws -> CGPoint {
        MouseHelpers.hideCursor()
        defer {
            MouseHelpers.showCursor()
        }
        let responseTask = Task.detached {
            while true {
                try Task.checkCancellation()
                let origin = try await self.getCurrentBounds(for: item).origin
                if origin != initialOrigin {
                    return origin
                }
                // Avoid spinning on the window server while waiting.
                try await Task.sleep(for: .milliseconds(1))
            }
        }
        let timeoutTask = Task(timeout: timeout) {
            try await withTaskCancellationHandler {
                try await responseTask.value
            } onCancel: {
                responseTask.cancel()
            }
        }
        do {
            let origin = try await timeoutTask.value
            logger.debug(
                """
                Item responded to events with new origin: \
                \(String(describing: origin), privacy: .public)
                """
            )
            return origin
        } catch let error as EventError {
            throw error
        } catch is TaskTimeoutError {
            throw EventError.itemResponseTimeout(item)
        } catch {
            throw EventError.cannotComplete
        }
    }

    /// Creates and posts a series of events to move a menu bar item
    /// to the given destination.
    ///
    /// - Parameters:
    ///   - item: The menu bar item to move.
    ///   - destination: The destination to move the menu bar item.
    private func postMoveEvents(item: MenuBarItem, destination: MoveDestination) async throws {
        try await eventSemaphore.waitUnlessCancelled()
        defer {
            eventSemaphore.signal()
        }

        var itemOrigin = try await getCurrentBounds(for: item).origin
        let targetPoints = try await getTargetPoints(forMoving: item, to: destination)
        let mouseLocation = try getMouseLocation()
        let source = try getEventSource()

        try permitLocalEvents()

        guard
            let mouseDown = CGEvent.menuBarItemEvent(
                item: item,
                source: source,
                type: .move(.mouseDown),
                location: targetPoints.start
            ),
            let mouseUp = CGEvent.menuBarItemEvent(
                item: destination.targetItem,
                source: source,
                type: .move(.mouseUp),
                location: targetPoints.end
            )
        else {
            throw EventError.eventCreationFailure(item)
        }

        var timeout = getMoveOperationTimeout(for: item)
        logger.debug("Move operation timeout: \(timeout)")

        lastMoveOperationTimestamp = .now
        MouseHelpers.hideCursor()
        defer {
            MouseHelpers.warpCursor(to: mouseLocation)
            MouseHelpers.showCursor()
            lastMoveOperationTimestamp = .now
            updateMoveOperationTimeout(timeout, for: item)
        }

        do {
            try await scrombleEvent(
                mouseDown,
                item: item,
                timeout: timeout
            )
            itemOrigin = try await waitForMoveEventResponse(
                from: item,
                initialOrigin: itemOrigin,
                timeout: timeout
            )
            // Release once, and again only if the item did not respond. Two
            // releases were always posted, and the second reached the item's
            // app after the drag had ended: a release with no press behind it,
            // on the item where it now sits. Apps that act on the release, such
            // as Mullvad VPN's, took it for a click and opened their window as
            // the item was hidden again (jordanbaird/Ice#766, #586).
            try await scrombleEvent(
                mouseUp,
                item: item,
                timeout: timeout
            )
            do {
                itemOrigin = try await waitForMoveEventResponse(
                    from: item,
                    initialOrigin: itemOrigin,
                    timeout: timeout
                )
            } catch EventError.itemResponseTimeout {
                logger.debug("Item did not respond to mouse up, posting it again")
                try await scrombleEvent(
                    mouseUp,
                    item: item,
                    timeout: timeout
                )
                itemOrigin = try await waitForMoveEventResponse(
                    from: item,
                    initialOrigin: itemOrigin,
                    timeout: timeout
                )
            }
            timeout -= timeout / 4
        } catch {
            do {
                logger.warning("Move events failed, posting fallback")
                try await scrombleEvent(
                    mouseUp,
                    item: item,
                    timeout: .milliseconds(100), // Fixed timeout for fallback.
                    repeating: 2 // Double mouse up prevents invalid item state.
                )
            } catch {
                // Catch this for logging purposes only. We want to propagate
                // the original error.
                logger.error("Fallback failed with error: \(error, privacy: .public)")
            }
            timeout += timeout / 2
            throw error
        }
    }

    /// Moves a menu bar item to the given destination.
    ///
    /// - Parameters:
    ///   - item: The menu bar item to move.
    ///   - destination: The destination to move the item to.
    func move(item: MenuBarItem, to destination: MoveDestination) async throws {
        if #available(macOS 27.0, *) {
            // macOS 27 ignores the drag events a move is made of.
            throw EventError.cannotComplete
        }
        guard item.isMovable else {
            throw EventError.itemNotMovable(item)
        }
        guard let appState else {
            throw EventError.cannotComplete
        }

        try await waitForUserToPauseInput()

        appState.hidEventManager.stopAll()
        defer {
            appState.hidEventManager.startAll()
        }

        try await waitForMoveOperationBuffer()

        logger.log(
            """
            Moving \(item.logString, privacy: .public) to \
            \(destination.logString, privacy: .public)
            """
        )

        guard try await !itemHasCorrectPosition(item: item, for: destination) else {
            logger.debug("Item has correct position, cancelling move")
            return
        }

        MouseHelpers.hideCursor()
        defer {
            MouseHelpers.showCursor()
        }

        let maxAttempts = 8
        for n in 1...maxAttempts {
            guard !Task.isCancelled else {
                throw EventError.cannotComplete
            }
            do {
                if try await itemHasCorrectPosition(item: item, for: destination) {
                    logger.debug("Item has correct position, finished with move")
                    return
                }
                try await postMoveEvents(item: item, destination: destination)
                logger.debug("Attempt \(n, privacy: .public) succeeded, finished with move")
                return
            } catch {
                logger.debug("Attempt \(n, privacy: .public) failed: \(error, privacy: .public)")
                if n < maxAttempts {
                    try await waitForMoveOperationBuffer()
                    continue
                }
                if error is EventError {
                    throw error
                }
                throw EventError.cannotComplete
            }
        }
    }
}

// MARK: - Clicking Items

extension MenuBarItemManager {
    /// Returns the equivalent event subtypes for clicking a menu bar
    /// item with the given mouse button.
    private nonisolated func getClickSubtypes(
        for mouseButton: CGMouseButton
    ) -> (down: MenuBarItemEventType.ClickSubtype, up: MenuBarItemEventType.ClickSubtype) {
        switch mouseButton {
        case .left: (.leftMouseDown, .leftMouseUp)
        case .right: (.rightMouseDown, .rightMouseUp)
        default: (.otherMouseDown, .otherMouseUp)
        }
    }

    /// Creates and posts a series of events to click a menu bar item.
    ///
    /// - Parameters:
    ///   - item: The menu bar item to click.
    ///   - mouseButton: The mouse button to click the item with.
    private func postClickEvents(item: MenuBarItem, mouseButton: CGMouseButton) async throws {
        try await eventSemaphore.waitUnlessCancelled()
        defer {
            eventSemaphore.signal()
        }

        let clickPoint = try await getCurrentBounds(for: item).center

        // A click posted off every display can't reach the item. Posted anyway,
        // it can land on whatever is at that edge of the screen, such as the
        // Apple menu at the left end of the menu bar (jordanbaird/Ice#642).
        guard Self.isOnDisplay(clickPoint) else {
            throw EventError.itemNotOnScreen(item)
        }

        let mouseLocation = try getMouseLocation()
        let source = try getEventSource()

        try permitLocalEvents()

        let clickTypes = getClickSubtypes(for: mouseButton)
        let timeout = Duration.milliseconds(250)

        guard
            let mouseDown = CGEvent.menuBarItemEvent(
                item: item,
                source: source,
                type: .click(clickTypes.down),
                location: clickPoint
            ),
            let mouseUp = CGEvent.menuBarItemEvent(
                item: item,
                source: source,
                type: .click(clickTypes.up),
                location: clickPoint
            )
        else {
            throw EventError.eventCreationFailure(item)
        }

        MouseHelpers.hideCursor()
        defer {
            MouseHelpers.warpCursor(to: mouseLocation)
            MouseHelpers.showCursor()
        }

        do {
            try await postEventWithBarrier(
                mouseDown,
                to: item,
                timeout: timeout
            )
            try await postEventWithBarrier(
                mouseUp,
                to: item,
                timeout: timeout,
                repeating: 2 // Double mouse up prevents invalid item state.
            )
        } catch {
            do {
                logger.warning("Click events failed, posting fallback")
                try await postEventWithBarrier(
                    mouseUp,
                    to: item,
                    timeout: timeout,
                    repeating: 2 // Double mouse up prevents invalid item state.
                )
            } catch {
                // Catch this for logging purposes only. We want to propagate
                // the original error.
                logger.error("Fallback failed with error: \(error, privacy: .public)")
            }
            throw error
        }
    }

    /// Returns a Boolean value that indicates whether the given point is
    /// on one of the displays.
    private static func isOnDisplay(_ point: CGPoint) -> Bool {
        NSScreen.screens.contains { CGDisplayBounds($0.displayID).contains(point) }
    }

    /// Returns a Boolean value that indicates whether the given item can be
    /// clicked where it is, without showing it first.
    ///
    /// An item counts as on screen when any part of it is on a display, but
    /// it is clicked at its center. An item only partly on a display was
    /// clicked off the display, and the click landed elsewhere, such as on
    /// the Apple menu (jordanbaird/Ice#642). Such an item is shown first.
    func canClickInPlace(_ item: MenuBarItem) -> Bool {
        guard
            Bridging.isWindowOnScreen(item.windowID),
            let bounds = Bridging.getWindowBounds(for: item.windowID)
        else {
            return false
        }
        return Self.isOnDisplay(bounds.center)
    }

    /// Clicks a menu bar item with the given mouse button.
    ///
    /// - Parameters:
    ///   - item: The menu bar item to click.
    ///   - mouseButton: The mouse button to click the item with.
    func click(item: MenuBarItem, with mouseButton: CGMouseButton) async throws {
        guard let appState else {
            throw EventError.cannotComplete
        }

        try await waitForUserToPauseInput()

        logger.log(
            """
            Clicking \(item.logString, privacy: .public) with \
            \(mouseButton.logString, privacy: .public)
            """
        )

        appState.hidEventManager.stopAll()
        defer {
            appState.hidEventManager.startAll()
        }

        let maxAttempts = 4
        for n in 1...maxAttempts {
            guard !Task.isCancelled else {
                throw EventError.cannotComplete
            }
            do {
                try await postClickEvents(item: item, mouseButton: mouseButton)
                logger.debug("Attempt \(n, privacy: .public) succeeded, finished with click")
                return
            } catch {
                logger.debug("Attempt \(n, privacy: .public) failed: \(error, privacy: .public)")
                if case EventError.itemNotOnScreen = error {
                    // Trying again would post the click in the same place.
                    throw error
                }
                if n < maxAttempts {
                    await eventSleep()
                    continue
                }
                if error is EventError {
                    throw error
                }
                throw EventError.cannotComplete
            }
        }
    }
}

// MARK: - Temporarily Showing Items

extension MenuBarItemManager {
    /// Context for a temporarily shown menu bar item.
    private final class TemporarilyShownItemContext {
        /// The tag associated with the item.
        let tag: MenuBarItemTag

        /// The item's window at the time it was shown.
        let windowID: CGWindowID

        /// The destination to return the item to.
        let returnDestination: MoveDestination

        /// The section the item came from.
        let returnSection: MenuBarSection.Name

        /// The window of the item's shown interface.
        var shownInterfaceWindow: WindowInfo?

        /// The number of attempts that have been made to rehide the item.
        var rehideAttempts = 0

        /// The number of rounds of attempts that have failed to rehide the item.
        var failedRehideRounds = 0

        /// A Boolean value that indicates whether the menu bar item's
        /// interface is showing.
        var isShowingInterface: Bool {
            guard
                let window = shownInterfaceWindow,
                let current = WindowInfo(windowID: window.windowID)
            else {
                // Window no longer exists, so assume closed.
                return false
            }
            if
                current.layer != CGWindowLevelForKey(.popUpMenuWindow),
                current.layer != CGWindowLevelForKey(.popUpMenuWindow) - 1,
                current.layer != CGWindowLevelForKey(.statusWindow),
                current.layer != CGWindowLevelForKey(.mainMenuWindow),
                let app = current.owningApplication
            {
                return app.isActive && current.isOnScreen
            }
            return current.isOnScreen
        }

        init(item: MenuBarItem, returnDestination: MoveDestination, returnSection: MenuBarSection.Name) {
            self.tag = item.tag
            self.windowID = item.windowID
            self.returnDestination = returnDestination
            self.returnSection = returnSection
        }

        /// Returns a Boolean value that indicates whether the given item
        /// is the one that was shown.
        ///
        /// Several items of one app can share a tag, such as OneDrive's
        /// items with more than one account signed in. Matching by tag
        /// alone treated all of them as shown, and they all dropped out
        /// of the cache (jordanbaird/Ice#857). The tag is only used when
        /// the shown item's window is gone, as when the app recreated
        /// the item.
        ///
        /// - Parameters:
        ///   - item: The item to check.
        ///   - windowIDs: The windows of the current menu bar items.
        func matches(_ item: MenuBarItem, windowIDs: Set<CGWindowID>) -> Bool {
            if windowIDs.contains(windowID) {
                return item.windowID == windowID
            }
            return item.tag == tag
        }
    }

    /// Gets the destination to return the given item to after it is
    /// temporarily shown.
    private func getReturnDestination(for item: MenuBarItem, in items: [MenuBarItem]) -> MoveDestination? {
        // Look for the item's window first. Several items of one app can
        // share a tag, and the first of them is not necessarily this one.
        guard let index = items.firstIndex(where: { $0.windowID == item.windowID }) ?? items.firstIndex(matching: item.tag) else {
            return nil
        }
        if items.indices.contains(index + 1) {
            return .leftOfItem(items[index + 1])
        }
        if items.indices.contains(index - 1) {
            return .rightOfItem(items[index - 1])
        }
        return nil
    }

    /// Schedules a timer for the given interval that rehides the
    /// temporarily shown items when fired.
    private func runRehideTimer(for interval: TimeInterval? = nil) {
        guard let appState else {
            return
        }
        let interval = interval ?? appState.settings.advanced.tempShowInterval
        logger.debug("Running rehide timer for interval: \(interval, format: .fixed, privacy: .public)")
        rehideTimer?.invalidate()
        rehideTimer = .scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            logger.debug("Rehide timer fired")
            Task {
                await self.rehideTemporarilyShownItems()
            }
        }
    }

    /// Temporarily shows the given item.
    ///
    /// The item is cached and returned to its original location after the
    /// time interval specified by ``AdvancedSettings/tempShowInterval``.
    ///
    /// - Parameters:
    ///   - item: The item to temporarily show.
    ///   - mouseButton: The mouse button to click the item with.
    func temporarilyShow(item: MenuBarItem, clickingWith mouseButton: CGMouseButton) async {
        guard let appState else {
            logger.error("Missing AppState, so not showing \(item.logString, privacy: .public)")
            return
        }
        if #available(macOS 27.0, *) {
            // Moving an item into view is not possible on macOS 27; use ItemClicker27.
            logger.error("Cannot temporarily show \(item.logString, privacy: .public) on macOS 27")
            return
        }
        guard let screen = NSScreen.screenWithActiveMenuBar else {
            logger.error("No active menu bar screen, so not showing \(item.logString, privacy: .public)")
            return
        }

        // List the items, which asks the menu bar item service for each
        // item's source process on macOS 26, while Accessibility is asked
        // for the application menu frame on this thread. Neither depends
        // on the other.
        async let currentItems = MenuBarItem.getMenuBarItems(option: .activeSpace)

        guard let applicationMenuFrame = screen.getApplicationMenuFrame() else {
            logger.error("No application menu frame, so not showing \(item.logString, privacy: .public)")
            return
        }

        var items = await currentItems

        guard let destination = getReturnDestination(for: item, in: items) else {
            logger.error("No return destination for \(item.logString, privacy: .public)")
            return
        }

        // The section the item returns to if its neighbor is gone by then, and
        // that it must be back in once it is moved back. Items left of the
        // always-hidden control item are always-hidden. Items right of the
        // hidden control item are visible: the search panel also shows visible
        // items that macOS has pushed off the menu bar.
        let returnSection: MenuBarSection.Name = {
            guard let itemIndex = items.firstIndex(where: { $0.windowID == item.windowID }) else {
                return .hidden
            }
            if
                let alwaysHiddenIndex = items.firstIndex(matching: .alwaysHiddenControlItem),
                itemIndex < alwaysHiddenIndex
            {
                return .alwaysHidden
            }
            if
                let hiddenIndex = items.firstIndex(matching: .hiddenControlItem),
                itemIndex > hiddenIndex
            {
                return .visible
            }
            return .hidden
        }()

        // Remove all items up to and including the hidden control item.
        if let index = items.firstIndex(matching: .hiddenControlItem) {
            items.removeSubrange(...index)
        }

        let maxX: CGFloat = {
            var maxX = applicationMenuFrame.maxX
            if let frameOfNotch = screen.frameOfNotch {
                maxX = max(maxX, frameOfNotch.maxX + 30)
            }
            return maxX + item.bounds.width
        }()

        // Remove items until we have enough room to show this item.
        items.trimPrefix { item in
            if item.isOnScreen && item.canBeHidden {
                return item.bounds.minX <= maxX
            }
            return true
        }

        guard let targetItem = items.first else {
            logger.warning("Not enough room to show \(item.logString, privacy: .public)")
            let alert = NSAlert()
            alert.messageText = "Not enough room to show \"\(item.displayName)\""
            alert.runModal()
            return
        }

        appState.hidEventManager.stopAll()
        defer {
            appState.hidEventManager.startAll()
        }

        logger.debug("Temporarily showing \(item.logString, privacy: .public)")

        temporaryMovesInProgress += 1
        defer {
            temporaryMovesInProgress -= 1
        }

        do {
            try await move(item: item, to: .leftOfItem(targetItem))
        } catch {
            logger.error("Error showing item: \(error, privacy: .public)")
            return
        }

        let context = TemporarilyShownItemContext(item: item, returnDestination: destination, returnSection: returnSection)
        temporarilyShownItemContexts.append(context)

        rehideTimer?.invalidate()
        defer {
            runRehideTimer()
        }

        await waitForItemToSettle(item)
        let idsBeforeClick = Set(Bridging.getWindowList(option: .onScreen))

        do {
            try await click(item: item, with: mouseButton)
        } catch {
            logger.error("Error clicking item: \(error, privacy: .public)")
            return
        }

        await eventSleep(for: .milliseconds(250))
        let windowsAfterClick = WindowInfo.createWindows(option: .onScreen)

        // Menu bar windows are not the item's interface. They stand at the
        // status window level and stay on screen, and before macOS 26 an app
        // owns its item windows, so an item the app added or recreated when
        // clicked counted as an open interface for as long as it was there,
        // and the shown item was never hidden again (jordanbaird/Ice#799, #513).
        let menuBarWindowIDs = Set(Bridging.getMenuBarWindowList())
        context.shownInterfaceWindow = windowsAfterClick.first { window in
            window.ownerPID == item.sourcePID &&
            !idsBeforeClick.contains(window.windowID) &&
            !menuBarWindowIDs.contains(window.windowID)
        }
    }

    /// Rehides all temporarily shown items.
    ///
    /// If an item is currently showing its interface, this method waits
    /// for the interface to close before hiding the items.
    func rehideTemporarilyShownItems() async {
        guard let appState else {
            logger.error("Missing AppState, so not rehiding")
            return
        }
        guard !temporarilyShownItemContexts.isEmpty else {
            return
        }
        guard !temporarilyShownItemContexts.contains(where: { $0.isShowingInterface }) else {
            logger.debug("Menu bar item interface is shown, so waiting to rehide")
            runRehideTimer(for: 3)
            return
        }
        guard hasUserPausedInput(for: .milliseconds(250)) else {
            logger.debug("Found recent user input, so waiting to rehide")
            runRehideTimer(for: 1)
            return
        }

        var currentContexts = temporarilyShownItemContexts
        temporarilyShownItemContexts.removeAll()

        temporaryMovesInProgress += 1
        defer {
            temporaryMovesInProgress -= 1
        }

        let items = await MenuBarItem.getMenuBarItems(option: .activeSpace)
        var failedContexts = [TemporarilyShownItemContext]()

        appState.hidEventManager.stopAll()
        defer {
            appState.hidEventManager.startAll()
        }

        await eventSleep(for: .milliseconds(250))

        logger.debug("Rehiding temporarily shown items")

        // Don't hide the pointer for the whole rehide. Each move hides it
        // once the user has paused input, and only while its events are
        // posted. Hiding it out here also hid it while each move waited for
        // the user to stop moving the mouse, so the pointer vanished for as
        // long as the user moved it looking for it, and through every retry
        // of an item that would not move back (jordanbaird/Ice#751, #757).

        let windowIDs = Set(items.map { $0.windowID })

        while let context = currentContexts.popLast() {
            guard let item = items.first(where: { context.matches($0, windowIDs: windowIDs) }) else {
                // The item is gone for now, usually because its app is quitting or
                // relaunching. Dropping the context left the item where it was shown:
                // macOS saved that position when the item was moved into view, so the
                // app put its item back there, in the visible section, from then on
                // (jordanbaird/Ice#513). Try again later, matching the item by its tag
                // once its window is gone, and give up after the usual rounds.
                context.failedRehideRounds += 1
                if context.failedRehideRounds < Self.maxFailedRehideRounds {
                    logger.debug("Item to rehide is missing, trying again later: \(context.tag, privacy: .public)")
                    failedContexts.append(context)
                } else {
                    logger.error("Giving up on rehiding missing item \(context.tag, privacy: .public)")
                }
                continue
            }
            do {
                try await move(item: item, to: currentReturnDestination(for: context, item: item, in: items))
                try await confirmReturn(of: item, to: context.returnSection, in: items)
            } catch {
                context.rehideAttempts += 1
                logger.warning(
                    """
                    Attempt \(context.rehideAttempts, privacy: .public) to rehide \
                    \(item.logString, privacy: .public) failed with error: \
                    \(error, privacy: .public)
                    """
                )
                if context.rehideAttempts < 3 {
                    currentContexts.append(context) // Try again.
                } else {
                    // Failed contexts are ultimately added back to the array
                    // and rehidden after a longer delay, so reset the count.
                    context.rehideAttempts = 0
                    context.failedRehideRounds += 1
                    if context.failedRehideRounds < Self.maxFailedRehideRounds {
                        failedContexts.append(context)
                    } else {
                        logger.error(
                            """
                            Giving up on rehiding \(item.logString, privacy: .public) \
                            after \(context.failedRehideRounds, privacy: .public) rounds \
                            of attempts
                            """
                        )
                    }
                }
            }
        }

        if failedContexts.isEmpty {
            logger.debug("All items were successfully rehidden")
        } else {
            logger.error(
                """
                Some items failed to rehide: \
                \(failedContexts.map { $0.tag }, privacy: .public)
                """
            )
            temporarilyShownItemContexts.append(contentsOf: failedContexts.reversed())
            let rounds = failedContexts.map(\.failedRehideRounds).max() ?? 1
            runRehideTimer(for: Self.rehideRetryInterval(afterFailedRounds: rounds))
        }
    }

    /// The number of failed rounds of rehide attempts after which a
    /// temporarily shown item is left where it is.
    ///
    /// Every round hides the cursor, pauses Ice's event monitors and posts
    /// synthetic drags. An item that could never be moved back was retried
    /// every 3 seconds for as long as Ice ran, which over a long session is
    /// tens of thousands of rounds of window server work.
    private static let maxFailedRehideRounds = 5

    /// The delay before the next round of rehide attempts, doubling from
    /// 3 seconds with each failed round, up to a minute.
    private static func rehideRetryInterval(afterFailedRounds rounds: Int) -> TimeInterval {
        let exponent = min(max(rounds - 1, 0), 5)
        return min(3 * pow(2, Double(exponent)), 60)
    }

    /// Returns the destination to return a temporarily shown item to,
    /// using the current window of the item it goes next to.
    ///
    /// That item can be recreated while the shown item is out, which gives
    /// it a new window. Moving next to the old window failed on every
    /// attempt, and the shown item stayed in view (jordanbaird/Ice#729). If
    /// the neighbor is gone altogether, the item goes back to the right end
    /// of the section it came from.
    private func currentReturnDestination(
        for context: TemporarilyShownItemContext,
        item: MenuBarItem,
        in items: [MenuBarItem]
    ) -> MoveDestination {
        let destination = context.returnDestination
        let target = destination.targetItem
        let others = items.filter { $0.windowID != item.windowID }
        guard
            let currentTarget = others.first(where: { $0.windowID == target.windowID }) ??
                others.first(matching: target.tag)
        else {
            // Return the item to the end of the section it came from, next to that
            // section's control item, so a temporary show never moves an item to
            // another section.
            let controlItemTag: MenuBarItemTag = context.returnSection == .alwaysHidden ? .alwaysHiddenControlItem : .hiddenControlItem
            guard let controlItem = others.first(matching: controlItemTag) else {
                return destination
            }
            logger.debug("Return destination for \(item.logString, privacy: .public) is gone, using the \(context.returnSection.logString, privacy: .public) section")
            return context.returnSection == .visible ? .rightOfItem(controlItem) : .leftOfItem(controlItem)
        }
        return switch destination {
        case .leftOfItem: .leftOfItem(currentTarget)
        case .rightOfItem: .rightOfItem(currentTarget)
        }
    }

    /// Makes sure that a temporarily shown item that was just moved back is
    /// in the section it came from, and moves it to the end of that section
    /// if it is not.
    ///
    /// A move counts as done as soon as the item's position changes after
    /// the drag events are posted. An item next to it that changes width,
    /// appears or goes away moves it as well, as a Live Activity from an
    /// iPhone does while it updates, so a move back that never happened
    /// could pass for one. The item's context was then dropped, and the item
    /// stayed in the visible section until it was moved by hand
    /// (jordanbaird/Ice#729, #513).
    ///
    /// - Parameters:
    ///   - item: The item that was moved back.
    ///   - section: The section the item came from.
    ///   - items: The menu bar items, as listed before the move.
    private func confirmReturn(
        of item: MenuBarItem,
        to section: MenuBarSection.Name,
        in items: [MenuBarItem]
    ) async throws {
        var others = items.filter { $0.windowID != item.windowID }
        guard let controlItems = ControlItemPair(items: &others) else {
            return
        }

        // Without the always-hidden section, its items return to the hidden one.
        let section: MenuBarSection.Name = section == .alwaysHidden && controlItems.alwaysHidden == nil ? .hidden : section

        // The live bounds of the item and the control items are read on every check.
        func isInSection() -> Bool {
            var context = CacheContext(controlItems: controlItems, displayID: nil)
            return context.findSection(for: item) == section
        }

        await waitForItemToSettle(item)
        if isInSection() {
            return
        }

        let destination: MoveDestination = switch section {
        case .visible: .rightOfItem(controlItems.hidden)
        case .hidden: .leftOfItem(controlItems.hidden)
        case .alwaysHidden: .leftOfItem(controlItems.alwaysHidden ?? controlItems.hidden)
        }
        logger.warning(
            """
            \(item.logString, privacy: .public) is not back in the \
            \(section.logString, privacy: .public), moving it \
            \(destination.logString, privacy: .public)
            """
        )
        try await move(item: item, to: destination)

        await waitForItemToSettle(item)
        guard isInSection() else {
            throw EventError.cannotComplete
        }
    }

    /// Removes a temporarily shown item from the cache, ensuring that
    /// the item is _not_ returned to its original location.
    func removeTemporarilyShownItemFromCache(for item: MenuBarItem) {
        // Several items of one app can share a tag, so a context for the
        // item's own window takes precedence over one that shares its tag.
        let hasWindowMatch = temporarilyShownItemContexts.contains { $0.windowID == item.windowID }
        while let index = temporarilyShownItemContexts.firstIndex(where: { context in
            hasWindowMatch ? context.windowID == item.windowID : context.tag == item.tag
        }) {
            logger.debug(
                """
                Removing temporarily shown item from cache: \
                \(item.tag, privacy: .public)
                """
            )
            temporarilyShownItemContexts.remove(at: index)
        }
    }
}

// MARK: - New Items

extension MenuBarItemManager {
    /// The apps whose menu bar items Icey has seen, so that an item from an
    /// app that adds one for the first time can be told apart from one that
    /// was there before.
    ///
    /// Items are remembered by their app, not their full tag: some apps change
    /// an item's title as their state changes, and each new title would look
    /// like a new item, moved again and again. An app that adds a second item
    /// later is not new, so that item stays where macOS puts it. The list keeps the order the items were
    /// first seen in, and is pruned from the oldest end once it grows past
    /// ``maxCount``, keeping any item that is in the menu bar.
    struct KnownItems {
        /// The number of items to remember.
        static let maxCount = 512

        /// The remembered keys, oldest first.
        private(set) var keys: [String]

        /// The remembered keys, for lookup.
        private var lookup: Set<String>

        /// Creates a list with the given keys, oldest first.
        init(keys: [String]) {
            self.keys = keys
            self.lookup = Set(keys)
        }

        /// Returns the key to remember the item with the given tag by, or
        /// `nil` if the tag does not identify its app across launches.
        ///
        /// A tag gets a random UUID namespace on macOS 26 when the app that
        /// created its item can't be found, and a `null` namespace when the
        /// owning process has no name. Neither names the same app twice.
        static func key(for tag: MenuBarItemTag) -> String? {
            guard tag.namespace.isString else {
                return nil
            }
            return tag.namespace.description
        }

        /// Adds the given key, and returns a Boolean value that indicates
        /// whether it was not remembered before.
        @discardableResult
        mutating func insert(_ key: String) -> Bool {
            guard lookup.insert(key).inserted else {
                return false
            }
            keys.append(key)
            return true
        }

        /// Forgets the oldest keys until no more than ``maxCount`` are left,
        /// skipping the given keys of items that are in the menu bar.
        mutating func prune(keeping present: Set<String>) {
            var excess = keys.count - Self.maxCount
            guard excess > 0 else {
                return
            }
            keys.removeAll { key in
                guard excess > 0, !present.contains(key) else {
                    return false
                }
                excess -= 1
                lookup.remove(key)
                return true
            }
        }
    }

    /// Remembers the items in the cache that Icey has not seen before,
    /// and queues them to be moved to the section chosen for new items.
    ///
    /// This runs after each cache update, so it adds no polling of its own.
    /// The first time it runs, every item is remembered and none is moved.
    /// An item is remembered before it is moved and is never moved again,
    /// so an item the user moves afterwards stays where they put it.
    private func recordNewItems(controlItems: ControlItemPair) {
        var candidates = [(item: MenuBarItem, section: MenuBarSection.Name, key: String)]()
        for section in MenuBarSection.Name.allCases {
            // The cache already leaves out items that can't be hidden.
            for item in itemCache[section] where !item.isControlItem && item.isMovable {
                guard let key = KnownItems.key(for: item.tag) else {
                    continue
                }
                candidates.append((item, section, key))
            }
        }

        guard var known = knownItems ?? Defaults.stringArray(forKey: .knownMenuBarItems).map({ KnownItems(keys: $0) }) else {
            // On macOS 26 an item's app can be missing for a moment, as when
            // the menu bar item service is starting. Such an item has no key,
            // and would look new once its app is found, so wait for it, up to
            // about a minute of cache updates.
            if
                itemCache.managedItems.contains(where: { $0.sourcePID == nil && !$0.isControlItem }),
                knownItemsSeedDeferrals < 12
            {
                knownItemsSeedDeferrals += 1
                return
            }
            var seeded = KnownItems(keys: [])
            for candidate in candidates {
                seeded.insert(candidate.key)
            }
            knownItems = seeded
            Defaults.set(seeded.keys, forKey: .knownMenuBarItems)
            logger.info("Remembered \(seeded.keys.count, privacy: .public) menu bar items as already seen")
            return
        }

        let target = targetSection(for: appState?.settings.general.newItemPlacement ?? .automatic, controlItems: controlItems)
        var foundNewItems = false

        // Every item of an app seen for the first time is new, not only the
        // first one found.
        var newKeys = Set<String>()
        for (item, section, key) in candidates {
            if known.insert(key) {
                newKeys.insert(key)
            }
            guard newKeys.contains(key) else {
                continue
            }
            foundNewItems = true
            logger.info("Found new menu bar item \(item.logString, privacy: .public) in the \(section.logString, privacy: .public)")
            if let target, target != section, !temporarilyShownItemContexts.contains(where: { $0.tag == item.tag }) {
                pendingNewItems.append(item)
            }
        }

        if foundNewItems {
            known.prune(keeping: Set(candidates.map(\.key)))
            Defaults.set(known.keys, forKey: .knownMenuBarItems)
        }
        knownItems = known

        placePendingNewItems()
    }

    /// Returns the section that new items are moved to for the given
    /// placement, or `nil` if they stay where macOS puts them.
    ///
    /// Without the always-hidden section, its items go to the hidden section.
    private func targetSection(for placement: NewItemPlacement, controlItems: ControlItemPair) -> MenuBarSection.Name? {
        guard let section = placement.section else {
            return nil
        }
        if section == .alwaysHidden, controlItems.alwaysHidden == nil {
            return .hidden
        }
        return section
    }

    /// Moves the queued new items one at a time, unless that is already
    /// being done.
    private func placePendingNewItems() {
        guard newItemPlacementTask == nil, !pendingNewItems.isEmpty else {
            return
        }
        newItemPlacementTask = Task { [weak self] in
            guard let self else {
                return
            }
            while !pendingNewItems.isEmpty {
                await placeNewItem(pendingNewItems.removeFirst())
            }
            newItemPlacementTask = nil
        }
    }

    /// Moves the given new item to the section chosen for new items, if it
    /// is still in the menu bar and not in that section already.
    ///
    /// The menu bar is read again first, as the setting, the item and the
    /// control items may all have changed since the item was queued. A move
    /// that fails is not retried: the item is remembered either way.
    private func placeNewItem(_ item: MenuBarItem) async {
        guard let placement = appState?.settings.general.newItemPlacement else {
            return
        }

        var items = await MenuBarItem.getMenuBarItems(option: .activeSpace)

        guard
            let controlItems = ControlItemPair(items: &items),
            let target = targetSection(for: placement, controlItems: controlItems),
            let current = items.first(where: { $0.windowID == item.windowID })
        else {
            return
        }

        var context = CacheContext(controlItems: controlItems, displayID: nil)
        guard context.findSection(for: current) != target else {
            return
        }

        let destination: MoveDestination
        switch target {
        case .visible:
            // Go to the left end of the visible section, next to its leftmost
            // item, as a temporarily shown item does while the hidden section
            // is collapsed.
            let visibleItems = items.filter { other in
                other.windowID != current.windowID && context.findSection(for: other) == .visible
            }
            if let leftmost = visibleItems.min(by: { $0.bounds.minX < $1.bounds.minX }) {
                destination = .leftOfItem(leftmost)
            } else {
                destination = .rightOfItem(controlItems.hidden)
            }
        case .hidden:
            destination = .leftOfItem(controlItems.hidden)
        case .alwaysHidden:
            destination = .leftOfItem(controlItems.alwaysHidden ?? controlItems.hidden)
        }

        logger.info("Moving new menu bar item \(current.logString, privacy: .public) to the \(target.logString, privacy: .public)")

        do {
            try await move(item: current, to: destination)
        } catch {
            logger.error("Error moving new menu bar item: \(error, privacy: .public)")
        }
    }
}

// MARK: - Control Item Order

extension MenuBarItemManager {
    /// Enforces the order of the given control items, ensuring that the
    /// control item for the always-hidden section is positioned to the
    /// left of control item for the hidden section.
    ///
    /// The always-hidden control item goes left of the items that were in
    /// the hidden section, not straight next to the hidden control item.
    /// Placing it next to the hidden control item moved every hidden item
    /// into the always-hidden section at once, leaving the hidden section
    /// empty (jordanbaird/Ice#702). When the previous cache doesn't say
    /// which items were hidden, as at launch, it goes left of all of them,
    /// so no item ends up harder to reach than before.
    ///
    /// - Parameters:
    ///   - controlItems: The control items, as listed with `items`.
    ///   - items: The other menu bar items, ordered from left to right.
    private func enforceControlItemOrder(controlItems: ControlItemPair, items: [MenuBarItem]) async {
        guard let alwaysHidden = controlItems.alwaysHidden else {
            return
        }

        // Check the order again with live bounds, as moving the always-hidden
        // control item rearranges the sections.
        let hiddenBounds = Bridging.getWindowBounds(for: controlItems.hidden.windowID) ?? controlItems.hidden.bounds
        let alwaysHiddenBounds = Bridging.getWindowBounds(for: alwaysHidden.windowID) ?? alwaysHidden.bounds

        guard hiddenBounds.maxX <= alwaysHiddenBounds.minX else {
            return
        }

        let itemsLeftOfHidden = items.filter { item in
            // The same tolerance as `findSection(for:)`, for items flush
            // against the divider on a scaled display.
            !item.isControlItem && !item.isSystemClone && item.bounds.maxX <= hiddenBounds.minX + Self.positionTolerance
        }
        let previousHiddenItems = itemCache[.hidden]
        // Match cached items by window first. A tag is only used for a cached
        // window that is gone, as several items can share one tag (several
        // OneDrive accounts, say), and one of them may be always-hidden.
        let liveWindowIDs = Set(items.map(\.windowID))
        let itemsThatWereHidden = itemsLeftOfHidden.filter { item in
            previousHiddenItems.contains { cached in
                if liveWindowIDs.contains(cached.windowID) {
                    return cached.windowID == item.windowID
                }
                return cached.tag == item.tag
            }
        }
        // Only an empty cache, as at launch, says nothing about which items were
        // hidden. A cache whose items are all gone means none of the items left
        // of the hidden divider were hidden, so they stay always-hidden.
        let candidates = previousHiddenItems.isEmpty ? itemsLeftOfHidden : itemsThatWereHidden

        let destination: MoveDestination = if let leftmost = candidates.min(by: { $0.bounds.minX < $1.bounds.minX }) {
            .leftOfItem(leftmost)
        } else {
            .leftOfItem(controlItems.hidden)
        }

        do {
            logger.debug("Control items have incorrect order, moving always-hidden control item \(destination.logString, privacy: .public)")
            try await move(item: alwaysHidden, to: destination)
        } catch {
            logger.error("Error enforcing control item order: \(error, privacy: .public)")
        }
    }
}

// MARK: - Control Item Positions

extension MenuBarItemManager {
    /// Saves where the control items are now as their preferred positions,
    /// so that macOS puts them back in the same places at the next launch.
    ///
    /// macOS restores a status item to its saved preferred position, a
    /// distance from the right edge of the screen, and saves that distance
    /// only when the item itself is dragged. Icey's control items stay put
    /// while other items move into and out of the sections next to them, so
    /// their saved positions fell behind the menu bar. At the next launch the
    /// dividers came back at the old distances: visible items and the Icey
    /// icon ended up in the hidden section and the order looked lost
    /// (jordanbaird/Ice#769), and hidden items ended up in the always-hidden
    /// section (jordanbaird/Ice#702).
    ///
    /// Each position is one point past the right edge of the item, so the
    /// item next to it on the right, whose saved position is no more than
    /// that edge, stays on its right. The always-hidden control item is only
    /// saved while the hidden section is hidden, the state the positions of
    /// hidden items are mostly saved in by Icey's own moves. Nothing is saved
    /// while an item is temporarily shown or being moved back, as it pushes
    /// the hidden control item to the left.
    func saveControlItemPositions() {
        if #available(macOS 27.0, *) {
            // Sections come from the saved layout on macOS 27.
            return
        }
        guard
            let appState,
            temporarilyShownItemContexts.isEmpty,
            temporaryMovesInProgress == 0,
            let windowIDs = controlItemWindowIDs,
            let hiddenBounds = Bridging.getWindowBounds(for: windowIDs.hidden)
        else {
            return
        }

        // Positions count from the right edge of the display the menu bar is on.
        let hiddenRightEdge = CGPoint(x: hiddenBounds.maxX - 1, y: hiddenBounds.midY)
        let displays = NSScreen.screens.map { CGDisplayBounds($0.displayID) }
        guard let displayBounds = displays.first(where: { $0.contains(hiddenRightEdge) }) else {
            return
        }

        func preferredPosition(for bounds: CGRect) -> CGFloat? {
            let position = (displayBounds.maxX - bounds.maxX).rounded() + 1
            guard position.isFinite, position > 0 else {
                return nil
            }
            return position
        }

        func save(_ position: CGFloat?, for identifier: ControlItem.Identifier) {
            guard let position else {
                return
            }
            logger.debug("Saving preferred position \(position, privacy: .public) for \(identifier.rawValue, privacy: .public)")
            ControlItemDefaults[.preferredPosition, identifier.rawValue] = position
        }

        let menuBarManager = appState.menuBarManager

        save(preferredPosition(for: hiddenBounds), for: .hidden)

        if
            menuBarManager.controlItem(withName: .visible)?.isAddedToMenuBar == true,
            let visibleItem = itemCache[.visible].first(matching: .visibleControlItem),
            let visibleBounds = Bridging.getWindowBounds(for: visibleItem.windowID),
            visibleBounds.minX >= hiddenBounds.maxX - Self.positionTolerance
        {
            save(preferredPosition(for: visibleBounds), for: .visible)
        }

        if
            menuBarManager.controlItem(withName: .hidden)?.state == .hideSection,
            menuBarManager.controlItem(withName: .alwaysHidden)?.isAddedToMenuBar == true,
            let alwaysHiddenWindowID = windowIDs.alwaysHidden,
            let alwaysHiddenBounds = Bridging.getWindowBounds(for: alwaysHiddenWindowID),
            alwaysHiddenBounds.maxX <= hiddenBounds.minX + Self.positionTolerance
        {
            save(preferredPosition(for: alwaysHiddenBounds), for: .alwaysHidden)
        }
    }
}

// MARK: - MenuBarItemEventType

/// Event types for menu bar item events.
private enum MenuBarItemEventType {
    /// The event type for moving a menu bar item.
    case move(MoveSubtype)
    /// The event type for clicking a menu bar item.
    case click(ClickSubtype)

    var cgEventType: CGEventType {
        switch self {
        case .move(let subtype): subtype.cgEventType
        case .click(let subtype): subtype.cgEventType
        }
    }

    var cgEventFlags: CGEventFlags {
        switch self {
        case .move(.mouseDown): .maskCommand
        case .move, .click: []
        }
    }

    var cgMouseButton: CGMouseButton {
        switch self {
        case .move: .left
        case .click(let subtype): subtype.cgMouseButton
        }
    }

    // MARK: Subtypes

    /// Subtype for menu bar item move events.
    enum MoveSubtype {
        case mouseDown
        case mouseUp

        var cgEventType: CGEventType {
            switch self {
            case .mouseDown: .leftMouseDown
            case .mouseUp: .leftMouseUp
            }
        }
    }

    /// Subtype for menu bar item click events.
    enum ClickSubtype {
        case leftMouseDown
        case leftMouseUp
        case rightMouseDown
        case rightMouseUp
        case otherMouseDown
        case otherMouseUp

        var cgEventType: CGEventType {
            switch self {
            case .leftMouseDown: .leftMouseDown
            case .leftMouseUp: .leftMouseUp
            case .rightMouseDown: .rightMouseDown
            case .rightMouseUp: .rightMouseUp
            case .otherMouseDown: .otherMouseDown
            case .otherMouseUp: .otherMouseUp
            }
        }

        var cgMouseButton: CGMouseButton {
            switch self {
            case .leftMouseDown, .leftMouseUp: .left
            case .rightMouseDown, .rightMouseUp: .right
            case .otherMouseDown, .otherMouseUp: .center
            }
        }

        var clickState: Int64 {
            switch self {
            case .leftMouseDown, .rightMouseDown, .otherMouseDown: 1
            case .leftMouseUp, .rightMouseUp, .otherMouseUp: 0
            }
        }
    }
}

// MARK: - CGEventField Helpers

private extension CGEventField {
    /// Key to access a field that contains the event's window identifier.
    static let windowID = CGEventField(rawValue: 0x33)! // swiftlint:disable:this force_unwrapping

    /// Fields that can be used to compare menu bar item events.
    static let menuBarItemEventFields: [CGEventField] = [
        .eventSourceUserData,
        .mouseEventWindowUnderMousePointer,
        .mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
        .windowID,
    ]
}

// MARK: - CGEventFilterMask Helpers

private extension CGEventFilterMask {
    /// Specifies that all events should be permitted during event suppression states.
    static let permitAllEvents: CGEventFilterMask = [
        .permitLocalMouseEvents,
        .permitLocalKeyboardEvents,
        .permitSystemDefinedEvents,
    ]
}

// MARK: - CGEventType Helpers

private extension CGEventType {
    /// A string to use for logging purposes.
    var logString: String {
        switch self {
        case .null: "null event"
        case .leftMouseDown: "leftMouseDown event"
        case .leftMouseUp: "leftMouseUp event"
        case .rightMouseDown: "rightMouseDown event"
        case .rightMouseUp: "rightMouseUp event"
        case .mouseMoved: "mouseMoved event"
        case .leftMouseDragged: "leftMouseDragged event"
        case .rightMouseDragged: "rightMouseDragged event"
        case .keyDown: "keyDown event"
        case .keyUp: "keyUp event"
        case .flagsChanged: "flagsChanged event"
        case .scrollWheel: "scrollWheel event"
        case .tabletPointer: "tabletPointer event"
        case .tabletProximity: "tabletProximity event"
        case .otherMouseDown: "otherMouseDown event"
        case .otherMouseUp: "otherMouseUp event"
        case .otherMouseDragged: "otherMouseDragged event"
        case .tapDisabledByTimeout: "tapDisabledByTimeout event"
        case .tapDisabledByUserInput: "tapDisabledByUserInput event"
        @unknown default: "unknown event"
        }
    }
}

// MARK: - CGMouseButton Helpers

private extension CGMouseButton {
    /// A string to use for logging purposes.
    var logString: String {
        switch self {
        case .left: "left mouse button"
        case .right: "right mouse button"
        case .center: "center mouse button"
        @unknown default: "unknown mouse button"
        }
    }
}

// MARK: - CGEvent Helpers

private extension CGEvent {
    /// Returns an event that can be sent to a menu bar item.
    ///
    /// - Parameters:
    ///   - item: The event's target item.
    ///   - source: The event's source.
    ///   - type: The event's specialized type.
    ///   - location: The event's location. Does not need to be
    ///     within the bounds of the item.
    static func menuBarItemEvent(
        item: MenuBarItem,
        source: CGEventSource,
        type: MenuBarItemEventType,
        location: CGPoint
    ) -> CGEvent? {
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: type.cgEventType,
            mouseCursorPosition: location,
            mouseButton: type.cgMouseButton
        ) else {
            return nil
        }
        event.setFlags(for: type)
        event.setUserData(ObjectIdentifier(event))
        event.setWindowID(item.windowID, for: type)
        event.setClickState(for: type)
        return event
    }

    /// Returns a null event with unique user data.
    static func uniqueNullEvent() -> CGEvent? {
        guard let event = CGEvent(source: nil) else {
            return nil
        }
        event.setUserData(ObjectIdentifier(event))
        return event
    }

    /// Posts the event to the given event tap location.
    ///
    /// - Parameter location: The event tap location to post the event to.
    func post(to location: EventTap.Location) {
        let type = self.type
        Logger.menuBarItemManager.debug(
            """
            Posting \(type.logString, privacy: .public) \
            to \(location.logString, privacy: .public)
            """
        )
        switch location {
        case .hidEventTap: post(tap: .cghidEventTap)
        case .sessionEventTap: post(tap: .cgSessionEventTap)
        case .annotatedSessionEventTap: post(tap: .cgAnnotatedSessionEventTap)
        case .pid(let pid): postToPid(pid)
        }
    }

    /// Returns a Boolean value that indicates whether the given integer
    /// fields from this event are equivalent to the same integer fields
    /// from the specified event.
    ///
    /// - Parameters:
    ///   - other: The event to compare with this event.
    ///   - fields: The integer fields to check.
    func matches(_ other: CGEvent, byIntegerFields fields: [CGEventField]) -> Bool {
        fields.allSatisfy { field in
            getIntegerValueField(field) == other.getIntegerValueField(field)
        }
    }

    func setTargetPID(_ pid: pid_t) {
        let targetPID = Int64(pid)
        setIntegerValueField(.eventTargetUnixProcessID, value: targetPID)
    }

    private func setFlags(for type: MenuBarItemEventType) {
        flags = type.cgEventFlags
    }

    private func setUserData(_ bitPattern: ObjectIdentifier) {
        let userData = Int64(Int(bitPattern: bitPattern))
        setIntegerValueField(.eventSourceUserData, value: userData)
    }

    private func setWindowID(_ windowID: CGWindowID, for type: MenuBarItemEventType) {
        let windowID = Int64(windowID)

        setIntegerValueField(.mouseEventWindowUnderMousePointer, value: windowID)
        setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: windowID)

        if case .move = type {
            setIntegerValueField(.windowID, value: windowID)
        }
    }

    private func setClickState(for type: MenuBarItemEventType) {
        if case .click(let subtype) = type {
            setIntegerValueField(.mouseEventClickState, value: subtype.clickState)
        }
    }
}

// MARK: - Logger Helpers

private extension Logger {
    /// Logger for the menu bar item manager.
    static let menuBarItemManager = Logger(category: "MenuBarItemManager")
}
