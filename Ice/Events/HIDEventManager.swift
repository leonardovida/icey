//
//  HIDEventManager.swift
//  Ice
//

import Carbon.HIToolbox
import Cocoa
import Combine
import OSLog

/// Manager that monitors input events and implements the features
/// that are triggered by them, such as showing hidden items on
/// click/hover/scroll.
@MainActor
final class HIDEventManager: ObservableObject {
    /// A Boolean value that indicates whether the user is dragging
    /// a menu bar item.
    @Published private(set) var isDraggingMenuBarItem = false {
        didSet {
            updateDragMonitors()
        }
    }

    /// The shared app state.
    private weak var appState: AppState?

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// History of the manager's enabled states.
    private var enabledStateStack = [Bool]()

    /// The last empty menu bar spot hovered on each display (see `ItemClicker27`).
    private var lastEmptyMenuBarPoints = [CGDirectDisplayID: CGPoint]()

    /// Until when the release of a held-back click is held back as well (see
    /// `handleSystemItemClick27`). The deadline keeps a release that never comes from
    /// swallowing an unrelated one later.
    private var heldBackReleaseUntil: ContinuousClock.Instant?

    /// The pending show-on-hover check, if there is one.
    private var showOnHoverTask: Task<Void, any Error>?

    /// Whether the pending show-on-hover check is for showing the hidden
    /// section (`true`) or hiding it (`false`).
    private var showOnHoverTaskShowsSection = false

    /// An identifier for the pending show-on-hover check.
    private var showOnHoverTaskID = UUID()

    /// The last answer to whether a display's menu bar is out of sight in a
    /// fullscreen space (see `isMenuBarConcealedByFullscreen(on:)`).
    private var fullscreenConcealment: (displayID: CGDirectDisplayID, checkedAt: ContinuousClock.Instant, isConcealed: Bool)?

    /// A Boolean value that indicates whether the manager is enabled.
    private var isEnabled = false {
        didSet {
            updateMonitors()
        }
    }

    /// A Boolean value that indicates whether the manager is enabled and
    /// the current settings need menu bar item drags to be detected.
    private var tracksMenuBarItemDrags = false

    /// A Boolean value that indicates whether the Command key is held, as
    /// last seen in a modifier key change or a left mouse down.
    private var isCommandKeyDown = false

    /// A Boolean value that indicates whether changes to the modifier keys
    /// may not be received (see `refreshModifierKeyState(with:)`).
    private var mayMissModifierKeyChanges = false

    // MARK: Monitors

    /// Monitor for mouse down events.
    private(set) lazy var mouseDownMonitor = EventMonitor.universal(
        for: [.leftMouseDown, .rightMouseDown]
    ) { [weak self] event in
        guard let self, isEnabled, let appState, let screen = bestScreen(appState: appState) else {
            return event
        }
        // Ice's own click that makes a display's menu bar active (see `ItemClicker27`).
        if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == HIDEventManager.menuBarActivationMarker {
            return event
        }
        switch event.type {
        case .leftMouseDown:
            refreshModifierKeyState(with: event)
            handleShowOnClick(with: event, appState: appState, screen: screen)
            handleSmartRehide(with: event, appState: appState, screen: screen)
        case .rightMouseDown:
            handleSecondaryContextMenu(appState: appState, screen: screen)
        default:
            return event
        }
        handlePreventShowOnHover(with: event, appState: appState, screen: screen)
        return event
    }

    /// Monitor for mouse up events.
    ///
    /// Runs only while a menu bar item drag can start or is in progress
    /// (see `updateDragMonitors()`).
    private(set) lazy var mouseUpMonitor = EventMonitor.universal(
        for: .leftMouseUp
    ) { [weak self] event in
        guard let self, isEnabled else {
            return event
        }
        handleMenuBarItemDragStop()
        return event
    }

    /// Monitor for mouse dragged events.
    ///
    /// Runs only while a drag can start a menu bar item drag, which needs
    /// the Command key (see `updateDragMonitors()`).
    private(set) lazy var mouseDraggedMonitor = EventMonitor.universal(
        for: .leftMouseDragged
    ) { [weak self] event in
        if let self, isEnabled, let appState, let screen = bestScreen(appState: appState) {
            handleMenuBarItemDragStart(with: event, appState: appState, screen: screen)
        }
        return event
    }

    /// Monitor for modifier key changes, which runs the drag monitors
    /// while the Command key is held.
    private(set) lazy var flagsChangedMonitor = EventMonitor.universal(
        for: .flagsChanged
    ) { [weak self] event in
        if let self, isEnabled {
            setCommandKeyDown(with: event)
        }
        return event
    }

    /// Tap for mouse moved events.
    private(set) lazy var mouseMovedTap = EventTap(
        type: .mouseMoved,
        location: .hidEventTap,
        placement: .tailAppendEventTap,
        option: .listenOnly
    ) { [weak self] _, event in
        if let self, isEnabled, let appState, let screen = bestScreen(appState: appState) {
            handleShowOnHover(appState: appState, screen: screen)
        }
        return event
    }

    /// Monitor for scroll wheel events.
    private(set) lazy var scrollWheelMonitor = EventMonitor.universal(
        for: .scrollWheel
    ) { [weak self] event in
        if let self, isEnabled, let appState, let screen = bestScreen(appState: appState) {
            handleShowOnScroll(with: event, appState: appState, screen: screen)
        }
        return event
    }

    /// Tap that lets clicks reach the system items while items are concealed on macOS 27.
    ///
    /// While an assessment-mode assertion is live, MenuBarAgent ignores clicks on the
    /// clock (measured on macOS 27.0). The tap holds such a click back, releases the
    /// assertions for a moment, and replays the click.
    private(set) lazy var systemItemClickTap = EventTap(
        types: [.leftMouseDown, .leftMouseUp],
        location: .hidEventTap,
        placement: .headInsertEventTap,
        option: .defaultTap
    ) { [weak self] _, event in
        guard let self, isEnabled, let appState else {
            return event
        }
        if #available(macOS 27.0, *) {
            return handleSystemItemClick27(event, appState: appState)
        }
        return event
    }

    // MARK: Setup

    /// Sets up the manager.
    func performSetup(with appState: AppState) {
        self.appState = appState
        configureCancellables()
        startAll()
    }

    /// Configures the internal observers for the manager.
    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        if let appState {
            // Only run the monitors that the current settings need. Monitors for
            // high-frequency events (mouse moved, dragged, scroll wheel) wake the app
            // for every such event in the system, even when the handlers return early.
            Publishers.Merge4(
                appState.settings.general.$showOnHover.replace(with: ()),
                appState.settings.general.$showOnScroll.replace(with: ()),
                appState.settings.advanced.$showAllSectionsOnUserDrag.replace(with: ()),
                appState.appearanceManager.$configuration.replace(with: ())
            )
            // Receive on the main queue, as the publishers emit before the new values are stored.
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.updateMonitors()
            }
            .store(in: &c)
        }

        if let appState, let hiddenSection = appState.menuBarManager.section(withName: .hidden) {
            // In fullscreen mode, the menu bar slides down from the top on hover. Observe the
            // frame of the hidden section's control item, which we know will always be in the
            // menu bar, and run the show-on-hover check when it changes.
            Publishers.CombineLatest3(
                hiddenSection.controlItem.$frame,
                appState.$activeSpace.map(\.isFullscreen),
                appState.menuBarManager.$isMenuBarHiddenBySystem
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak appState] _, isFullscreen, isMenuBarHiddenBySystem in
                guard let self, isEnabled, let appState, isFullscreen || isMenuBarHiddenBySystem else {
                    return
                }
                if let screen = bestScreen(appState: appState) {
                    handleShowOnHover(appState: appState, screen: screen)
                }
            }
            .store(in: &c)
        }

        cancellables = c
    }

    // MARK: Start/Stop

    /// Starts or stops each monitor, according to whether the manager is
    /// enabled and whether the current settings need the monitor.
    private func updateMonitors() {
        let general = appState?.settings.general

        // Dragging shows all sections and fades out the overlay panels.
        var needsDragMonitors = false
        if let appState {
            let appearanceManager = appState.appearanceManager
            needsDragMonitors = appState.settings.advanced.showAllSectionsOnUserDrag ||
                appearanceManager.mayNeedOverlayPanels(for: appearanceManager.configuration)
        }

        let monitors: [(any EventMonitorProtocol, Bool)] = [
            (mouseDownMonitor, true),
            (flagsChangedMonitor, needsDragMonitors),
            (mouseMovedTap, general?.showOnHover == true),
            (scrollWheelMonitor, general?.showOnScroll == true),
        ]
        for (monitor, isNeeded) in monitors {
            if isEnabled && isNeeded {
                monitor.start()
            } else {
                monitor.stop()
            }
        }
        if #available(macOS 27.0, *) {
            if isEnabled {
                systemItemClickTap.start()
            } else {
                systemItemClickTap.stop()
            }
        }

        // Key changes made while the monitors were stopped weren't received.
        tracksMenuBarItemDrags = isEnabled && needsDragMonitors
        refreshModifierKeyState(with: nil)

        if !needsDragMonitors {
            // The mouse up event that ends a drag can't be received while
            // the monitor is stopped, so don't leave the drag in progress.
            handleMenuBarItemDragStop()
        }
        if general?.showOnHover != true {
            cancelShowOnHoverTask()
        }
    }

    /// Starts or stops the mouse dragged and mouse up monitors.
    ///
    /// A drag only starts a menu bar item drag while the Command key is held
    /// (see `handleMenuBarItemDragStart(with:appState:screen:)`). Every other
    /// drag in the system, such as selecting text or moving a window, woke the
    /// app for each event, so drag events are received only while the key is
    /// held. The mouse up monitor runs from then on until the drag ends, so
    /// the release that ends it is never missed.
    private func updateDragMonitors() {
        let needsDragEvents = tracksMenuBarItemDrags && (isCommandKeyDown || mayMissModifierKeyChanges)
        let needsMouseUpEvents = needsDragEvents || (tracksMenuBarItemDrags && isDraggingMenuBarItem)
        for (monitor, isNeeded) in [(mouseDraggedMonitor, needsDragEvents), (mouseUpMonitor, needsMouseUpEvents)] {
            if isNeeded {
                monitor.start()
            } else {
                monitor.stop()
            }
        }
    }

    /// Records whether the Command key is held after a modifier key change.
    private func setCommandKeyDown(with event: NSEvent) {
        guard tracksMenuBarItemDrags else {
            return
        }
        // The key state is asked as well, so that an event posted without
        // the key never hides that the user holds it.
        isCommandKeyDown = event.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.command)
        updateDragMonitors()
    }

    /// Records whether the Command key is held, and whether its changes can
    /// be missed, when the monitors start and at each left mouse down.
    private func refreshModifierKeyState(with event: NSEvent?) {
        guard tracksMenuBarItemDrags else {
            isCommandKeyDown = false
            mayMissModifierKeyChanges = false
            updateDragMonitors()
            return
        }
        // Key events from other apps, modifier key changes included, are only
        // received with Accessibility, and may not be while secure input is on.
        // Drag events are then received throughout, as they were before, so a
        // drag that only gains the Command key once it is underway still counts.
        mayMissModifierKeyChanges = IsSecureEventInputEnabled() ||
            appState?.permissions.accessibility.hasPermission != true
        isCommandKeyDown = event?.modifierFlags.contains(.command) == true || NSEvent.modifierFlags.contains(.command)
        updateDragMonitors()
    }

    /// Starts all monitors.
    func startAll() {
        isEnabled = enabledStateStack.popLast() ?? true
    }

    /// Stops all monitors.
    func stopAll() {
        enabledStateStack.append(isEnabled)
        isEnabled = false
    }
}

// MARK: - Handler Methods

extension HIDEventManager {

    // MARK: Handle Show On Click

    private func handleShowOnClick(with event: NSEvent, appState: AppState, screen: NSScreen) {
        guard
            appState.settings.general.showOnClick,
            isMouseInsideEmptyMenuBarSpace(appState: appState, screen: screen)
        else {
            return
        }

        // One window list serves both checks below.
        let windows = WindowInfo.createWindows(option: .onScreen)

        guard
            // A click while a menu is open is the click that closes it, not
            // one on the menu bar. Navigating an app's menus showed the hidden
            // items whenever the menus could not be measured (jordanbaird/Ice#567).
            !isMenuOpen(on: screen, in: windows),
            // A click at the top of the screen in Mission Control is a click on
            // its spaces (jordanbaird/Ice#714).
            !isMissionControlActive(in: windows)
        else {
            return
        }

        // The keys held for this click, rather than whatever is held once the
        // task below runs (see `ModifierFlags.clickModifiers`).
        let modifiers = event.modifierFlags.clickModifiers

        Task {
            if modifiers == .control {
                handleSecondaryContextMenu(appState: appState, screen: screen)
                return
            }

            let targetSection: MenuBarSection

            if
                modifiers == .option,
                let alwaysHiddenSection = appState.menuBarManager.section(withName: .alwaysHidden),
                alwaysHiddenSection.isEnabled
            {
                targetSection = alwaysHiddenSection
            } else if
                let hiddenSection = appState.menuBarManager.section(withName: .hidden),
                hiddenSection.isEnabled
            {
                targetSection = hiddenSection
            } else {
                return
            }

            targetSection.toggle()
        }
    }

    // MARK: Handle Smart Rehide

    private func handleSmartRehide(with event: NSEvent, appState: AppState, screen: NSScreen) {
        guard
            appState.settings.general.autoRehide,
            case .smart = appState.settings.general.rehideStrategy
        else {
            return
        }

        // The hidden section kept shown for the active display isn't
        // rehidden. Unless the always-hidden section is shown as well,
        // there is nothing to check, so don't ask the window server.
        if
            appState.menuBarManager.autoShowManager.keepsHiddenSectionShown,
            appState.menuBarManager.section(withName: .alwaysHidden)?.isHidden ?? true
        {
            return
        }

        // Make sure clicking the Ice icon doesn't trigger rehide.
        if let iceIcon = appState.menuBarManager.controlItem(withName: .visible) {
            guard event.window !== iceIcon.window else {
                return
            }
        }

        // Only continue if the click is not inside the Ice Bar, at
        // least one section is visible, and the mouse is not inside
        // the menu bar.
        guard
            event.window !== appState.menuBarManager.iceBarPanel,
            appState.menuBarManager.hasVisibleSection,
            !isMouseInsideMenuBar(appState: appState, screen: screen)
        else {
            return
        }

        let initialSpaceID = Bridging.getActiveSpaceID()

        Task {
            // Give the window under the mouse a chance to focus.
            try await Task.sleep(for: .milliseconds(250))

            // Don't bother checking the window if the click caused
            // a space change.
            if Bridging.getActiveSpaceID() != initialSpaceID {
                for section in appState.menuBarManager.sections {
                    section.rehide()
                }
                return
            }

            guard let mouseLocation = MouseHelpers.locationCoreGraphics else {
                return
            }

            // One window list, taken now, serves both checks below.
            let windows = WindowInfo.createWindows(option: .onScreen)

            // A click inside a menu bar app's popover or a menu, such as on a
            // switch or a brightness slider, is not a click outside the menu
            // bar. The search below skips untitled windows, so it found the
            // window behind the popover, and hiding the items closed the popover
            // (jordanbaird/Ice#403, #526).
            if menuBarInterfaceWindows(on: screen, in: windows).contains(where: { $0.bounds.contains(mouseLocation) }) {
                return
            }

            // Get the window that was clicked.
            let windowsUnderMouse = windows.filter { window in
                window.layer < CGWindowLevelForKey(.cursorWindow) && window.bounds.contains(mouseLocation)
            }
            guard
                let windowIndex = windowsUnderMouse.firstIndex(where: { $0.title?.isEmpty == false }),
                let owningApplication = windowsUnderMouse[windowIndex].owningApplication
            else {
                return
            }
            let windowUnderMouse = windowsUnderMouse[windowIndex]

            // Note: The Dock is an exception to the following checks.
            if owningApplication.bundleIdentifier != "com.apple.dock" {
                // Don't hide the sections for a click in one of the app's menus
                // or popovers, which sit above normal windows. It is likely the
                // interface of one of the shown items, which closed as soon as
                // its item was hidden (jordanbaird/Ice#621).
                guard !windowsUnderMouse[...windowIndex].contains(where: { window in
                    window.ownerPID == windowUnderMouse.ownerPID &&
                    window.layer > CGWindowLevelForKey(.normalWindow)
                }) else {
                    return
                }

                // Only continue if the clicked app is active, and has
                // a regular activation policy.
                guard
                    owningApplication.isActive,
                    owningApplication.activationPolicy == .regular
                else {
                    return
                }
            }

            // All checks have passed, hide the sections.
            for section in appState.menuBarManager.sections {
                section.rehide()
            }
        }
    }

    // MARK: Handle Secondary Context Menu

    private func handleSecondaryContextMenu(appState: AppState, screen: NSScreen) {
        Task {
            guard
                appState.settings.advanced.enableSecondaryContextMenu,
                isMouseInsideEmptyMenuBarSpace(appState: appState, screen: screen),
                let mouseLocation = MouseHelpers.locationAppKit
            else {
                return
            }
            // Delay prevents the menu from immediately closing.
            try await Task.sleep(for: .milliseconds(100))
            appState.menuBarManager.showSecondaryContextMenu(at: mouseLocation)
        }
    }

    // MARK: Handle Menu Bar Item Drag Stop

    private func handleMenuBarItemDragStop() {
        if isDraggingMenuBarItem {
            isDraggingMenuBarItem = false
        }
    }

    // MARK: Handle Menu Bar Item Drag Start

    private func handleMenuBarItemDragStart(with event: NSEvent, appState: AppState, screen: NSScreen) {
        guard
            !isDraggingMenuBarItem,
            event.modifierFlags.contains(.command),
            isMouseInsideMenuBar(appState: appState, screen: screen)
        else {
            return
        }

        isDraggingMenuBarItem = true

        if appState.settings.advanced.showAllSectionsOnUserDrag {
            for section in appState.menuBarManager.sections {
                section.controlItem.state = .showSection
            }
        }
    }

    // MARK: Handle System Item Clicks (macOS 27)

    /// Marks the clicks Ice replays, so the tap lets them through.
    private static let replayedClickMarker: Int64 = 0x1CE_27_C1C

    /// Times the steps of a bridged click, which happen on both opening and closing a panel.
    private static let bridgeLogger = Logger(subsystem: "com.jordanbaird.Ice", category: "ClickBridge27")

    /// Marks Ice's click that makes a display's menu bar active before an item is pressed.
    static let menuBarActivationMarker: Int64 = 0x1CE_27_BA2

    /// The last empty menu bar spot hovered on the given display.
    func lastEmptyMenuBarPoint(for displayID: CGDirectDisplayID) -> CGPoint? {
        lastEmptyMenuBarPoints[displayID]
    }

    /// System items that do not open from an Accessibility press, so a click on them has to
    /// go through MenuBarAgent. Seeded with what was measured on macOS 27.0; anything else
    /// that turns out to ignore the press joins them at its first click.
    private nonisolated(unsafe) static var systemItemsIgnoringPress: Set<String> = [
        "com.apple.menuextra.clock",
        "com.apple.menuextra.battery",
        "com.apple.menuextra.wifi",
    ]

    /// The system item whose panel Ice last opened, so a second click on the same item is
    /// understood as the click that dismisses it.
    private nonisolated(unsafe) static var itemShowingPanel: String?

    @available(macOS 27.0, *)
    private func handleSystemItemClick27(_ event: CGEvent, appState: AppState) -> CGEvent? {
        guard event.getIntegerValueField(.eventSourceUserData) != Self.replayedClickMarker else {
            return event
        }
        if event.type == .leftMouseUp {
            // A press Ice holds back has its release held back with it. MenuBarAgent would
            // otherwise be handed a release with no press behind it, moments before the
            // replayed click that carries both.
            guard let until = heldBackReleaseUntil, ContinuousClock.now < until else {
                heldBackReleaseUntil = nil
                return event
            }
            heldBackReleaseUntil = nil
            return nil
        }
        let concealer = appState.concealer27
        // The frames of the display the click landed on, so the clock of the display whose bar
        // is not active is recognised as well.
        let clickedDisplay = NSScreen.screens.first { CGDisplayBounds($0.displayID).contains(event.location) }?.displayID
        let framesOnDisplay = clickedDisplay.map { MenuBarItemProvider27.systemItemFrames(for: $0) } ?? []
        guard ClockBridgeZone27.shouldBridge(
            click: event.location,
            systemItemFrames: framesOnDisplay.isEmpty ? MenuBarItemProvider27.systemItemFrames() : framesOnDisplay,
            isConcealing: concealer.isConcealing
        ) else {
            return event
        }
        let location = event.location
        // Control Centre opens from an Accessibility press even while items are concealed
        // (measured on macOS 27.0: its panel appears after about 177 ms). The clock, the
        // battery and Wi-Fi ignore the press, so for those the concealment is lifted and the
        // click replayed — and put back the moment their panel is up, rather than after a
        // fixed second and a half, which is what made every hidden item flash into view.
        let systemItem = MenuBarItemProvider27.systemItem(at: location)
        let mayOpenFromPress = systemItem.map { !Self.systemItemsIgnoringPress.contains($0.identifier) } ?? false
        // An application's item drawn over by a system item at or right of the clicked one gets
        // its slot back when concealment is lifted, and the clicked item moves (see
        // `ClockBridgeZone27.clickedItemMayMove`). Every other click is replayed where it was made.
        let clickedFrame = systemItem.flatMap { MenuBarItemProvider27.systemItemFrame(withIdentifier: $0.identifier) }
        let clickedItemMayMove = clickedFrame.map { clickedFrame in
            ClockBridgeZone27.clickedItemMayMove(
                clickedFrame: clickedFrame,
                systemItemFrames: MenuBarItemProvider27.systemItemFrames(),
                applicationItemFrames: MenuBarItemProvider27.applicationItemFrames()
            )
        } ?? false
        Task {
            // A click that lands while a panel is up is the click that dismisses it, and
            // Escape dismisses it just as well — with no lift of concealment at all. Lifting
            // for such a click brought every hidden item back on screen first, and the panel
            // only answered once MenuBarAgent had finished moving the bar: the icons appeared,
            // and the panel closed late behind them.
            // A banner shows in the same window as the panel — same process, same level, the
            // size of the display (measured on macOS 27.0) — so the window alone cannot say
            // whether a panel is open, and a click that arrived while a banner happened to be
            // up was answered with Escape, dismissing the banner instead of opening the panel.
            // A click is treated as dismissing a panel only when Ice opened one itself and its
            // window is still there; a panel opened some other way is closed by the replayed
            // click, as it would be without Ice.
            if Self.itemShowingPanel != nil, ItemClick27.openPanelWindow(windows: Self.windowsForPanelCheck()) != nil {
                Self.postEscape()
                Self.bridgeLogger.debug("Click bridge: a panel was open, dismissed with Escape")
                guard systemItem?.identifier != Self.itemShowingPanel else {
                    Self.itemShowingPanel = nil
                    return
                }
                // A different system item was clicked, so its own panel still has to open.
                try? await Task.sleep(for: Self.panelDismissWait)
            }
            if mayOpenFromPress, let systemItem {
                let baseline = Self.windowNumbers()
                await Self.press(systemItem.element)
                if await Self.waitForPanel(baseline: baseline, pollsOf50ms: 5) {
                    // Remembered here as well, or the next click on this item would dismiss
                    // its panel and open it again in the same breath.
                    Self.itemShowingPanel = systemItem.identifier
                    return
                }
                // Waiting for a panel that never comes only delays the click, so an item
                // that ignored the press is not asked again while Ice runs.
                Self.systemItemsIgnoringPress.insert(systemItem.identifier)
            }
            // The click is replayed the moment the assertion is really gone rather than on a
            // timer: releasing it queues behind other concealment work, and MenuBarAgent ignores
            // a click that arrives while the assertion still stands, which is why the clock
            // sometimes did nothing and opened on the second try. Nothing else is done before
            // the replay, so the click is as quick as the release allows.
            let bridgeStarted = ProcessInfo.processInfo.systemUptime
            Self.bridgeLogger.debug("Click bridge: holding the click, lifting concealment")
            if clickedItemMayMove, let systemItem {
                // MenuBarAgent moves the bar 50–150 ms after the release, so reading the item's
                // frame straight after it is too early: Ice waits for the item to move, up to
                // `itemMoveWait`, with the lift extended by as much, and clicks it where it went
                // (measured on macOS 27.0.1, jordanbaird/Ice#1014).
                let before = await MenuBarItemProvider27.systemItemFrame(
                    withIdentifier: systemItem.identifier,
                    afterMovingFrom: nil,
                    timeout: .zero
                ) ?? clickedFrame
                await concealer.suspendReleased(for: Self.clickRestoreDelay + Self.itemMoveWait)
                let after = await MenuBarItemProvider27.systemItemFrame(
                    withIdentifier: systemItem.identifier,
                    afterMovingFrom: before,
                    timeout: Self.itemMoveWait
                )
                var target = location
                if let before, let after {
                    target = ClockBridgeZone27.relocatedClick(location, from: before, to: after)
                }
                let released = (ProcessInfo.processInfo.systemUptime - bridgeStarted) * 1000
                Self.replayClick(at: target)
                Self.itemShowingPanel = systemItem.identifier
                Self.bridgeLogger.debug("Click bridge: lifted in \(released, privacy: .public) ms, click replayed on the moved item")
                return
            }
            await concealer.suspendReleased(for: Self.clickRestoreDelay)
            let released = (ProcessInfo.processInfo.systemUptime - bridgeStarted) * 1000
            Self.replayClick(at: location)
            Self.itemShowingPanel = systemItem?.identifier
            Self.bridgeLogger.debug("Click bridge: lifted in \(released, privacy: .public) ms, click replayed")
        }
        heldBackReleaseUntil = .now + .seconds(1)
        return nil
    }

    /// How long concealment stays lifted around a replayed click.
    ///
    /// MenuBarAgent needs the lift to act on the click at all, and every millisecond of it is
    /// a millisecond of the bar moving: the items slide back in, then out again. The panel's
    /// own window appears about 166 ms after the click (measured on macOS 27.0), so a lift
    /// that ends around then has the bar settling while the panel animates, which is what made
    /// the animation stutter.
    ///
    /// Measured on macOS 27.0 with `Scripts/macos27/clock-restore.swift`, on both displays: a
    /// lift of 40 ms loses the click 6 times in 16, 60 ms once in 16, and 80, 100 and 120 ms
    /// each opened the panel 16 times in 16. So the floor is around 60 ms, and 120 ms keeps
    /// double that margin while still ending before the panel appears. The
    /// `MacOS27ClickRestoreDelay` default overrides it, in milliseconds, for measuring.
    private static var clickRestoreDelay: Duration {
        let stored = Defaults.integer(forKey: .macOS27ClickRestoreDelay)
        return .milliseconds(stored > 0 ? min(max(stored, 30), 2000) : 120)
    }

    /// The longest Ice waits for a clicked system item to move once concealment is lifted. The
    /// bar moves 50–150 ms after the release (measured on macOS 27.0.1, jordanbaird/Ice#1014).
    private static let itemMoveWait = Duration.milliseconds(200)



    /// The window numbers currently on screen.
    private static func windowNumbers() -> Set<Int> {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(windows.compactMap { $0[kCGWindowNumber as String] as? Int })
    }

    /// The processes that draw the system items' panels.
    ///
    /// Without this, the Dock passes for an open panel: its window stands at layer 20 and the
    /// full size of the display, and it is always there, so every click looked like a click
    /// that closes a panel and every wait for that panel to go ran into its timeout (measured
    /// on macOS 27.0: 12 clicks in a row judged "panel already open").
    private static let panelOwnerBundleIDs: Set<String> = [
        "com.apple.notificationcenterui",
        "com.apple.controlcenter",
    ]

    /// The windows on screen that could be a system item's panel, as `ItemClick27` wants them.
    private static func windowsForPanelCheck() -> [(number: Int, layer: Int, height: CGFloat)] {
        let owners = Set(
            NSWorkspace.shared.runningApplications
                .filter { panelOwnerBundleIDs.contains($0.bundleIdentifier ?? "") }
                .map(\.processIdentifier)
        )
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.compactMap { window in
            guard
                let number = window[kCGWindowNumber as String] as? Int,
                let layer = window[kCGWindowLayer as String] as? Int,
                let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t,
                owners.contains(ownerPID),
                let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                let height = bounds["Height"]
            else {
                return nil
            }
            return (number: number, layer: layer, height: height)
        }
    }

    /// How long the panel that was open takes to go after Escape, before the item that was
    /// clicked is given its own turn.
    private static let panelDismissWait = Duration.milliseconds(120)

    /// Presses Escape, which dismisses an open system panel.
    ///
    /// Notification Center and Control Centre both answer it while items stay concealed, so a
    /// click that dismisses a panel needs no lift of concealment at all.
    private static func postEscape() {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: down)?.post(tap: .cghidEventTap)
        }
    }

    /// Waits for a system item's panel to appear.
    @available(macOS 27.0, *)
    private static func waitForPanel(baseline: Set<Int>, pollsOf50ms: Int) async -> Bool {
        for _ in 0..<pollsOf50ms {
            try? await Task.sleep(for: .milliseconds(50))
            if ItemClick27.panelOpened(before: baseline, windows: windowsForPanelCheck()) {
                return true
            }
        }
        return false
    }

    /// Presses an Accessibility element off the main thread, which the call can block.
    private static func press(_ element: AXUIElement) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                _ = AXUIElementPerformAction(element, kAXPressAction as CFString)
                continuation.resume()
            }
        }
    }

    private static func replayClick(at location: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            guard let event = CGEvent(
                mouseEventSource: source,
                mouseType: type,
                mouseCursorPosition: location,
                mouseButton: .left
            ) else {
                continue
            }
            event.setIntegerValueField(.eventSourceUserData, value: replayedClickMarker)
            event.post(tap: .cghidEventTap)
        }
    }

    // MARK: Handle Show On Hover

    private func handleShowOnHover(appState: AppState, screen: NSScreen) {
        // Make sure the "ShowOnHover" feature is enabled.
        //
        // `showOnHoverAllowed` is deliberately *not* checked here. It is cleared
        // when the user clicks in the menu bar, so that hovering does not
        // immediately undo a deliberate click, and it is restored only inside
        // `MenuBarSection.hide()`. Checking it here disabled the hide-on-leave
        // branch below as well — and that branch is what calls `hide()`. The flag
        // therefore latched off the only mechanism that could clear it, leaving
        // the Ice Bar on screen indefinitely: on whatever display it was opened
        // on, while the user worked on another one. It is checked in the reveal
        // branch instead, where it belongs.
        guard appState.settings.general.showOnHover else {
            return
        }

        // Only continue if we have a hidden section (we should).
        guard let hiddenSection = appState.menuBarManager.section(withName: .hidden) else {
            return
        }

        let delay = appState.settings.advanced.showOnHoverDelay
        let isHidden = hiddenSection.isHidden

        // Mouse moved events arrive at the pointer's polling rate. Keep a single
        // check pending at a time, rather than spawning a task for every event.
        if showOnHoverTask != nil {
            guard showOnHoverTaskShowsSection != isHidden else {
                return
            }
            cancelShowOnHoverTask()
        }

        if isHidden {
            // Perform the cheap geometric checks up front. The checks that query
            // Accessibility and the window server run in the pending task.
            guard
                appState.menuBarManager.showOnHoverAllowed,
                isMouseInsideMenuBar(appState: appState, screen: screen),
                !isMouseInsideNotch(appState: appState, screen: screen)
            else {
                return
            }
            startShowOnHoverTask(showsSection: true) { [weak self] in
                guard let self else {
                    return
                }
                guard isMouseInsideEmptyMenuBarSpace(appState: appState, screen: screen) else {
                    // The mouse is likely moving over the application menus or the
                    // items. Wait briefly before allowing another check, as each one
                    // is expensive.
                    try await Task.sleep(for: .milliseconds(50))
                    return
                }
                recordEmptyMenuBarPoint(on: screen)
                try await Task.sleep(for: .seconds(delay))
                // Make sure the mouse is still inside.
                guard isMouseInsideEmptyMenuBarSpace(appState: appState, screen: screen) else {
                    return
                }
                // While a menu is open, the pointer is moving between menus,
                // not resting on an empty part of the menu bar. Navigating an
                // app's menus showed the hidden items whenever the menus could
                // not be measured (jordanbaird/Ice#567). Wait before allowing
                // another check, as each one asks the window server.
                guard !isMenuOpen(on: screen) else {
                    try await Task.sleep(for: .milliseconds(250))
                    return
                }
                // In Mission Control, the top of the screen holds the spaces,
                // and the menu bar items stay where they were underneath, so
                // reaching for a space showed the hidden items
                // (jordanbaird/Ice#714).
                guard !isMissionControlActive() else {
                    try await Task.sleep(for: .milliseconds(250))
                    return
                }
                recordEmptyMenuBarPoint(on: screen)
                hiddenSection.show()
            }
        } else {
            // The hidden section kept shown for the active display isn't
            // rehidden, so don't start a check on every mouse move.
            guard
                !appState.menuBarManager.autoShowManager.keepsHiddenSectionShown,
                !isMouseInsideMenuBar(appState: appState, screen: screen),
                !isMouseInsideOrAwaitingIceBar(appState: appState)
            else {
                return
            }
            startShowOnHoverTask(showsSection: false) { [weak self] in
                try await Task.sleep(for: .seconds(delay))
                guard let self else {
                    return
                }
                // Make sure the mouse is still outside.
                guard
                    !isMouseInsideMenuBar(appState: appState, screen: screen),
                    !isMouseInsideOrAwaitingIceBar(appState: appState)
                else {
                    return
                }
                // The pointer leaves the menu bar to use the menu or popover
                // of a shown item, and hiding the items closed it
                // (jordanbaird/Ice#452). The delay can be zero, so wait before
                // allowing another check, as each one asks the window server.
                guard menuBarInterfaceWindows(on: screen).isEmpty else {
                    try await Task.sleep(for: .milliseconds(250))
                    return
                }
                hiddenSection.rehide()
            }
        }
    }

    /// Starts the pending show-on-hover check with the given operation.
    private func startShowOnHoverTask(showsSection: Bool, operation: @escaping @MainActor () async throws -> Void) {
        let taskID = UUID()
        showOnHoverTaskID = taskID
        showOnHoverTaskShowsSection = showsSection
        showOnHoverTask = Task { [weak self] in
            defer {
                if self?.showOnHoverTaskID == taskID {
                    self?.showOnHoverTask = nil
                }
            }
            try await operation()
        }
    }

    /// Cancels the pending show-on-hover check, if there is one.
    private func cancelShowOnHoverTask() {
        showOnHoverTask?.cancel()
        showOnHoverTask = nil
        showOnHoverTaskID = UUID()
    }

    /// Records the mouse location as the last empty menu bar spot hovered
    /// on the given screen.
    private func recordEmptyMenuBarPoint(on screen: NSScreen) {
        if let location = MouseHelpers.locationCoreGraphics {
            lastEmptyMenuBarPoints[screen.displayID] = location
        }
    }

    // MARK: Handle Prevent Show On Hover

    private func handlePreventShowOnHover(with event: NSEvent, appState: AppState, screen: NSScreen) {
        guard
            appState.settings.general.showOnHover,
            !appState.settings.usesIceBar(on: screen)
        else {
            return
        }

        guard isMouseInsideMenuBar(appState: appState, screen: screen) else {
            return
        }

        if isMouseInsideMenuBarItem(appState: appState, screen: screen) {
            switch event.type {
            case .leftMouseDown:
                if appState.menuBarManager.hasVisibleSection {
                    break
                }
                if isMouseInsideIceIcon(appState: appState) {
                    break
                }
                return
            case .rightMouseDown:
                if appState.menuBarManager.hasVisibleSection {
                    break
                }
                return
            default:
                return
            }
        } else if isMouseInsideApplicationMenu(appState: appState, screen: screen) {
            return
        }

        // Mouse is inside the menu bar, outside an item or application
        // menu, so it must be inside an empty menu bar space. Set it only
        // on a change, as this runs for every click there.
        if appState.menuBarManager.showOnHoverAllowed {
            appState.menuBarManager.showOnHoverAllowed = false
        }
    }

    // MARK: Handle Show On Scroll

    private func handleShowOnScroll(with event: NSEvent, appState: AppState, screen: NSScreen) {
        guard
            appState.settings.general.showOnScroll,
            isMouseInsideMenuBar(appState: appState, screen: screen),
            let hiddenSection = appState.menuBarManager.section(withName: .hidden)
        else {
            return
        }

        let averageDelta = (event.scrollingDeltaX + event.scrollingDeltaY) / 2

        // Trackpads report deltas in points. A mouse wheel reports them in
        // lines, about one per notch, so the threshold for points was never
        // reached with a wheel (jordanbaird/Ice#717).
        let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 5 : 0

        if averageDelta > threshold {
            hiddenSection.show()
        } else if averageDelta < -threshold {
            hiddenSection.hide()
        }
    }
}

// MARK: - Helper Methods

extension HIDEventManager {
    /// Returns the best screen to use for event manager calculations.
    /// Uses the screen under the mouse so menu bar hover/click work correctly
    /// with multiple displays (e.g. external monitor).
    func bestScreen(appState: AppState) -> NSScreen? {
        NSScreen.screenWithMouse ?? NSScreen.main
    }

    /// A Boolean value that indicates whether the mouse pointer is within
    /// the bounds of the menu bar.
    func isMouseInsideMenuBar(appState: AppState, screen: NSScreen) -> Bool {
        guard let mouseLocation = MouseHelpers.locationAppKit else {
            return false
        }

        // With "Displays have separate Spaces" turned off, only the primary
        // display has a menu bar. The top of every other display is ordinary
        // window space, and counting it as a menu bar swallowed clicks there
        // and opened Ice's menu on right-click (jordanbaird/Ice#456, #646).
        guard
            NSScreen.screensHaveSeparateSpaces ||
            screen.displayID == NSScreen.screens.first?.displayID
        else {
            return false
        }

        // The bottom edge of the menu bar.
        var menuBarMinY = screen.visibleFrame.maxY

        // Whether the control item below is in this screen's menu bar.
        var isControlItemOnScreen = false

        // The Ice icon must be vertically visible. Otherwise, we can infer
        // that the menu bar is hidden and the mouse is not inside.
        //
        // With "Show Icey icon" turned off, the icon is not in the menu bar, and
        // its window keeps the frame it had when it was removed. The hidden
        // section's control item, which is always in the menu bar, is used
        // instead. Going by the removed icon, the top of a fullscreen app counted
        // as the menu bar while the menu bar was out of sight, and clicking there
        // showed the hidden items, on a single display too (jordanbaird/Ice#899).
        //
        // On macOS 27 the icon's window is only a placeholder, and its frame says
        // nothing about the menu bar (measured past a display's left edge, below its
        // bottom, and with no height). The visible frame check below remains.
        if #unavailable(macOS 27.0) {
            let controlItem: ControlItem? = if let iceIcon = appState.menuBarManager.controlItem(withName: .visible), iceIcon.isAddedToMenuBar {
                iceIcon
            } else {
                appState.menuBarManager.controlItem(withName: .hidden)
            }
            guard
                let controlItemFrame = controlItem?.frame,
                controlItemFrame.maxY <= screen.frame.maxY
            else {
                return false
            }
            // A menu bar that the system hides and shows automatically takes no
            // space from the visible frame, so only the top row of the screen
            // counted as the menu bar. Show on hover and click needed the pointer
            // against the edge, and shown items collapsed as soon as it moved
            // down onto the revealed menu bar (jordanbaird/Ice#708). The control
            // item is as tall as the menu bar it sits in, so while it is on this
            // screen, its bottom edge is the menu bar's. A point at its right edge
            // is checked, both ways, because stacked displays can share a horizontal
            // range, and a collapsed section's divider reaches far off the left edge.
            if screen.frame.contains(CGPoint(x: controlItemFrame.maxX - 1, y: controlItemFrame.midY)) {
                menuBarMinY = min(menuBarMinY, controlItemFrame.minY)
                isControlItemOnScreen = true
            }
        }

        // Infer the menu bar frame from the screen frame.
        let isInsideFrame = mouseLocation.x >= screen.frame.minX &&
            mouseLocation.x <= screen.frame.maxX &&
            mouseLocation.y <= screen.frame.maxY &&
            mouseLocation.y >= menuBarMinY

        // A control item in another display's menu bar says nothing about whether
        // this one is revealed. Asked only when the pointer is at the top of
        // the screen, and only before macOS 27 (see above).
        if #unavailable(macOS 27.0) {
            if isInsideFrame && !isControlItemOnScreen {
                return !isMenuBarConcealedByFullscreen(on: screen)
            }
        }
        return isInsideFrame
    }

    /// A Boolean value that indicates whether the mouse pointer is within
    /// the bounds of the current application menu.
    func isMouseInsideApplicationMenu(appState: AppState, screen: NSScreen) -> Bool {
        guard let mouseLocation = MouseHelpers.locationCoreGraphics else {
            return false
        }
        guard var applicationMenuFrame = screen.getApplicationMenuFrame() else {
            return false
        }
        if #available(macOS 27.0, *) {
            // The menus come from the application that owns the menu bar, so the frame is in its
            // display's coordinates whichever display is asked about. See `ApplicationMenuArea27`.
            return Self.applicationMenuArea27(menuFrame: applicationMenuFrame, screen: screen)
                .contains(mouseLocation)
        }
        applicationMenuFrame.size.width += applicationMenuFrame.origin.x - screen.frame.origin.x
        applicationMenuFrame.origin.x = screen.frame.origin.x
        return applicationMenuFrame.contains(mouseLocation)
    }

    /// How far an application's menus reached on a display, the last time it was the active one
    /// there. Each display draws the menus of whatever is frontmost on it, and Accessibility
    /// describes only the active display's, so this is the one exact measurement to be had of
    /// the others (measured on macOS 27.0: asked about any display, Accessibility answers with
    /// the active one's menu bar, in its coordinates).
    private nonisolated(unsafe) static var menuReachByDisplay: [CGDirectDisplayID: [String: CGFloat]] = {
        // Kept across launches: the measurement can only be taken while the display is the active
        // one, and starting with none of it means guessing at every bar until the user has gone
        // round the displays again.
        guard let stored = Defaults.dictionary(forKey: .macOS27MenuReach) as? [String: [String: Double]] else {
            return [:]
        }
        return stored.reduce(into: [:]) { result, pair in
            guard let displayID = CGDirectDisplayID(pair.key) else {
                return
            }
            result[displayID] = pair.value.mapValues { CGFloat($0) }
        }
    }()

    /// Which application last owned the menu bar of each display.
    ///
    /// A display that is not the active one goes on drawing the menus of the application that was
    /// last active on it, which is not the same as whatever window happens to lie topmost there —
    /// measured 2026-10-08, where the topmost window on the external display belonged to one
    /// application and its bar was drawing another's menus.
    private nonisolated(unsafe) static var menuOwnerByDisplay: [CGDirectDisplayID: String] = {
        guard let stored = Defaults.dictionary(forKey: .macOS27MenuOwner) as? [String: String] else {
            return [:]
        }
        return stored.reduce(into: [:]) { result, pair in
            guard let displayID = CGDirectDisplayID(pair.key) else {
                return
            }
            result[displayID] = pair.value
        }
    }()

    private static func rememberMenuReach(_ reach: CGFloat, forApplication bundleID: String, on displayID: CGDirectDisplayID) {
        if menuOwnerByDisplay[displayID] != bundleID {
            menuOwnerByDisplay[displayID] = bundleID
            Defaults.set(
                menuOwnerByDisplay.reduce(into: [String: String]()) { $0[String($1.key)] = $1.value },
                forKey: .macOS27MenuOwner
            )
        }
        guard menuReachByDisplay[displayID]?[bundleID] != reach else {
            return
        }
        menuReachByDisplay[displayID, default: [:]][bundleID] = reach
        let stored = menuReachByDisplay.reduce(into: [String: [String: Double]]()) { result, pair in
            result[String(pair.key)] = pair.value.mapValues { Double($0) }
        }
        Defaults.set(stored, forKey: .macOS27MenuReach)
    }

    /// The application frontmost on the given display, by its topmost ordinary window there.
    private static func frontmostApplication(on displayBounds: CGRect) -> String? {
        WindowInfo.createWindows(option: .onScreen)
            .first { $0.layer == 0 && displayBounds.intersects($0.bounds) }?
            .owningApplication?
            .bundleIdentifier
    }

    /// The stretch of the given screen's bar the application menus occupy on macOS 27.
    @available(macOS 27.0, *)
    private static func applicationMenuArea27(menuFrame: CGRect, screen: NSScreen) -> CGRect {
        let displayBounds = CGDisplayBounds(screen.displayID)
        let ownerScreen = NSScreen.screens.first { CGDisplayBounds($0.displayID).intersects(menuFrame) } ?? screen
        let ownerBounds = CGDisplayBounds(ownerScreen.displayID)
        if
            ownerScreen == screen,
            let owner = NSWorkspace.shared.menuBarOwningApplication?.bundleIdentifier
        {
            // Measurable right now, so it is remembered for when this display is not the active
            // one and the same application is still frontmost on it.
            Self.rememberMenuReach(menuFrame.maxX - displayBounds.minX, forApplication: owner, on: screen.displayID)
        }
        var rememberedReach: CGFloat?
        if
            ownerScreen != screen,
            // The application whose menus that bar is drawing: the one that last owned the menu
            // bar there, or, until Ice has seen that happen, whatever lies topmost on it.
            let drawing = Self.menuOwnerByDisplay[screen.displayID] ?? Self.frontmostApplication(on: displayBounds)
        {
            rememberedReach = ApplicationMenuArea27.reach(
                onThisDisplay: Self.menuReachByDisplay[screen.displayID]?[drawing],
                onOtherDisplays: Self.menuReachByDisplay
                    .filter { $0.key != screen.displayID }
                    .compactMap { $0.value[drawing] }
            )
        }
        // A notch on the owning display sits inside the measurement whenever the menus reach past
        // it, and no other display has it.
        var notchGap: CGFloat = 0
        if
            ownerScreen != screen,
            let left = ownerScreen.auxiliaryTopLeftArea,
            let right = ownerScreen.auxiliaryTopRightArea,
            menuFrame.maxX - ownerBounds.minX > left.width
        {
            notchGap = max(right.minX - left.maxX, 0)
        }
        return ApplicationMenuArea27.area(
            menuFrame: menuFrame,
            ownerDisplay: ownerBounds,
            display: displayBounds,
            barHeight: screen.getMenuBarHeight() ?? menuFrame.height,
            notchGap: notchGap,
            itemsLeftEdge: ownerScreen == screen ? nil : MenuBarItemProvider27.leftEdge(for: screen.displayID),
            rememberedReach: rememberedReach
        )
    }

    /// A Boolean value that indicates whether the mouse pointer is within
    /// the bounds of a menu bar item.
    func isMouseInsideMenuBarItem(appState: AppState, screen: NSScreen) -> Bool {
        guard let mouseLocation = MouseHelpers.locationCoreGraphics else {
            return false
        }
        if #available(macOS 27.0, *) {
            // There are no item windows on macOS 27. See `ItemHitTest27`.
            let items = appState.itemManager.itemCache.managedItems.map { item in
                ItemHitTest27.Item(frame: item.bounds, ownerPID: item.ownerPID, isOnScreen: item.isOnScreen)
            }
            let systemFrames = MenuBarItemProvider27.systemItemFrames()
                + [MenuBarItemProvider27.overflowButtonFrame(), CaptureIndicatorPanel27.indicatorFrame()].compactMap { $0 }
            return ItemHitTest27.isInsideItem(
                point: mouseLocation,
                items: items,
                concealedPIDs: appState.concealer27.concealedPIDs,
                systemFrames: systemFrames
            )
        }
        let windowIDs = Bridging.getMenuBarWindowList(option: [.onScreen, .activeSpace, .itemsOnly])
        return windowIDs.contains { windowID in
            guard let bounds = Bridging.getWindowBounds(for: windowID) else {
                return false
            }
            return bounds.contains(mouseLocation)
        }
    }

    /// A Boolean value that indicates whether the mouse pointer is within
    /// the bounds of the screen's notch, if it has one.
    ///
    /// If the screen does not have a notch, this property returns `false`.
    func isMouseInsideNotch(appState: AppState, screen: NSScreen) -> Bool {
        guard
            let mouseLocation = MouseHelpers.locationAppKit,
            var frameOfNotch = screen.frameOfNotch
        else {
            return false
        }
        frameOfNotch.size.height += 1
        return frameOfNotch.contains(mouseLocation)
    }

    /// A Boolean value that indicates whether the mouse pointer is within
    /// the bounds of an empty space in the menu bar.
    func isMouseInsideEmptyMenuBarSpace(appState: AppState, screen: NSScreen) -> Bool {
        // Perform the cheap geometric checks before the ones that query
        // Accessibility and the window server.
        guard
            isMouseInsideMenuBar(appState: appState, screen: screen),
            !isMouseInsideNotch(appState: appState, screen: screen),
            !isMouseInsideApplicationMenu(appState: appState, screen: screen),
            !isMouseInsideMenuBarItem(appState: appState, screen: screen)
        else {
            return false
        }
        if #available(macOS 27.0, *) {
            // The gaps between items are part of the items' own run of the bar.
            return !isMouseInsideItemsArea(appState: appState, screen: screen)
        }
        return true
    }

    /// A Boolean value that indicates whether the mouse pointer rests in the part of the
    /// menu bar that holds items, including the gaps between them.
    @available(macOS 27.0, *)
    func isMouseInsideItemsArea(appState: AppState, screen: NSScreen) -> Bool {
        guard let mouseLocation = MouseHelpers.locationCoreGraphics else {
            return false
        }
        let items = appState.itemManager.itemCache.managedItems.map { item in
            ItemHitTest27.Item(frame: item.bounds, ownerPID: item.ownerPID, isOnScreen: item.isOnScreen)
        }
        let systemFrames = MenuBarItemProvider27.systemItemFrames()
            + [MenuBarItemProvider27.overflowButtonFrame(), CaptureIndicatorPanel27.indicatorFrame()].compactMap { $0 }
        return ItemHitTest27.isInsideItemsArea(
            point: mouseLocation,
            displayBounds: CGDisplayBounds(screen.displayID),
            items: items,
            concealedPIDs: appState.concealer27.concealedPIDs,
            systemFrames: systemFrames,
            rememberedLeftEdge: MenuBarItemProvider27.leftEdge(for: screen.displayID)
        )
    }

    /// A Boolean value that indicates whether the mouse pointer is within
    /// the bounds of the Ice Bar panel.
    func isMouseInsideIceBar(appState: AppState) -> Bool {
        let panel = appState.menuBarManager.iceBarPanel
        // A closed panel keeps the frame it had when it was last shown.
        // A panel fading out is already closed.
        guard
            panel.isVisible,
            !panel.isFadingOut,
            let mouseLocation = MouseHelpers.locationAppKit
        else {
            return false
        }
        // Pad the frame to be more forgiving if the user accidentally
        // moves their mouse outside of the Ice Bar.
        let paddedFrame = panel.frame.insetBy(dx: -15, dy: -15)
        return paddedFrame.contains(mouseLocation)
    }

    /// A Boolean value that indicates whether the Ice Bar should stay open
    /// for the mouse pointer: the pointer is within it, or it has been asked
    /// to open and is not on screen yet.
    ///
    /// The pointer leaves the menu bar on its way down to the Ice Bar. Rehide
    /// checks that counted every point below the menu bar as "outside" closed
    /// the bar before the pointer reached it, or while it was being used
    /// (jordanbaird/Ice#914).
    func isMouseInsideOrAwaitingIceBar(appState: AppState) -> Bool {
        appState.menuBarManager.iceBarPanel.isAwaitingDisplay || isMouseInsideIceBar(appState: appState)
    }

    /// Returns the menus, popovers and panels that are open just below the
    /// menu bar of the given screen, front to back.
    ///
    /// A menu bar item opens its menu or popover as a window whose top edge
    /// meets the bottom of the menu bar. Hiding the items while one is open
    /// moves the item it belongs to, and the app closes it: a menu closed
    /// under the pointer by timed rehide or show on hover (jordanbaird/Ice#452),
    /// and a switch or slider in another app's popover closed by smart rehide
    /// (#403, #526). Counted are menus, from any app, and the floating windows
    /// of apps that run without a Dock icon, as menu bar apps do. An ordinary
    /// window is not counted, even when it reaches up to the menu bar.
    ///
    /// This asks the window server for one window list, unless the on screen
    /// windows are passed in `windows`, so it is only called when the items
    /// are about to be shown or hidden, never per event.
    func menuBarInterfaceWindows(
        on screen: NSScreen,
        in windows: [WindowInfo] = WindowInfo.createWindows(option: .onScreen)
    ) -> [WindowInfo] {
        let displayBounds = CGDisplayBounds(screen.displayID)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let cursorLevel = Int(CGWindowLevelForKey(.cursorWindow))

        // The bottom edge of the menu bar, in window server coordinates.
        let menuBarBottom: CGFloat = {
            if let menuBarWindow = WindowInfo.menuBarWindow(from: windows, for: screen.displayID) {
                return menuBarWindow.bounds.maxY
            }
            let reservedHeight = screen.frame.maxY - screen.visibleFrame.maxY
            return displayBounds.minY + max(reservedHeight, NSStatusBar.system.thickness)
        }()

        return windows.filter { window in
            guard
                window.ownerPID != ownPID,
                !window.isWindowServerWindow,
                window.layer >= 0,
                window.layer < cursorLevel,
                window.bounds.width > 20,
                window.bounds.height > 20,
                displayBounds.intersects(window.bounds),
                // Hangs from the menu bar. A window that covers the menu bar
                // itself, such as another app's tint overlay, starts above it.
                window.bounds.minY >= menuBarBottom - 2,
                window.bounds.minY <= menuBarBottom + 40
            else {
                return false
            }
            if window.layer == menuLevel {
                return true
            }
            // A popover or panel floats above ordinary windows, which an app
            // without a Dock icon can also have, such as a settings window.
            guard window.layer > 0, let app = window.owningApplication else {
                return false
            }
            return app.activationPolicy != .regular && app.bundleIdentifier != "com.apple.dock"
        }
    }

    /// A Boolean value that indicates whether a menu is open just below the
    /// menu bar of the given screen.
    func isMenuOpen(
        on screen: NSScreen,
        in windows: [WindowInfo] = WindowInfo.createWindows(option: .onScreen)
    ) -> Bool {
        let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        return menuBarInterfaceWindows(on: screen, in: windows).contains { $0.layer == menuLevel }
    }

    /// A Boolean value that indicates whether Mission Control is open.
    ///
    /// This asks the window server for one window list, unless the on screen
    /// windows are passed in `windows`, so it is only called when the items
    /// are about to be shown, never per event.
    func isMissionControlActive(in windows: [WindowInfo] = WindowInfo.createWindows(option: .onScreen)) -> Bool {
        WindowInfo.isMissionControlActive(in: windows)
    }

    /// A Boolean value that indicates whether the given screen's menu bar is
    /// out of sight in a fullscreen space.
    ///
    /// In a fullscreen space the system shows the menu bar only while it is
    /// revealed, and the top of the screen belongs to the fullscreen app the
    /// rest of the time. The Ice icon cannot tell this when it sits in the
    /// menu bar of another display, which it does until the fullscreen app is
    /// focused: clicking the top of a fullscreen app on a second display
    /// counted as a click on its menu bar and showed the hidden items
    /// (jordanbaird/Ice#899). The display's own menu bar window, which is only
    /// on that display while the menu bar is revealed, is asked instead.
    ///
    /// Mouse moved events at the top of the screen ask this as often as the
    /// pointer reports, so the answer is kept for a quarter of a second.
    private func isMenuBarConcealedByFullscreen(on screen: NSScreen) -> Bool {
        let displayID = screen.displayID
        let now = ContinuousClock.now
        if
            let cached = fullscreenConcealment,
            cached.displayID == displayID,
            now - cached.checkedAt < .milliseconds(250)
        {
            return cached.isConcealed
        }
        var isConcealed = false
        if
            let space = SpaceInfo.currentSpace(for: displayID),
            space.spaceID != 0,
            space.isFullscreen
        {
            isConcealed = WindowInfo.menuBarWindow(for: displayID) == nil
        }
        fullscreenConcealment = (displayID, now, isConcealed)
        return isConcealed
    }

    /// A Boolean value that indicates whether the mouse pointer is within
    /// the bounds of the Ice icon.
    func isMouseInsideIceIcon(appState: AppState) -> Bool {
        guard
            let visibleSection = appState.menuBarManager.section(withName: .visible),
            let iceIconFrame = visibleSection.controlItem.frame,
            let mouseLocation = MouseHelpers.locationAppKit
        else {
            return false
        }
        return iceIconFrame.contains(mouseLocation)
    }
}

// MARK: - Click Modifiers

extension NSEvent.ModifierFlags {
    /// The keys a click is made with: Shift, Control, Option and Command.
    ///
    /// The flags also carry Caps Lock, the Function key, the numeric keypad
    /// and device-dependent bits. Comparing them whole against `.option`
    /// failed whenever one of those was set, so Option-click only showed the
    /// always-hidden section some of the time (jordanbaird/Ice#644).
    var clickModifiers: NSEvent.ModifierFlags {
        intersection([.shift, .control, .option, .command])
    }
}

// MARK: - EventMonitor Helpers

/// Helper protocol to enable group operations across event
/// monitoring types.
@MainActor
private protocol EventMonitorProtocol {
    func start()
    func stop()
}

extension EventMonitor: EventMonitorProtocol { }

extension EventTap: EventMonitorProtocol {
    fileprivate func start() {
        enable()
    }

    fileprivate func stop() {
        disable()
    }
}
