//
//  EventManager.swift
//  Ice
//

import Cocoa
import Combine

/// Manager for the various event monitors maintained by the app.
@MainActor
final class EventManager {
    /// The shared app state.
    private weak var appState: AppState?

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// A Boolean value that indicates whether the monitors should be running.
    private var isRunning = false

    /// The task that performs the delayed show-on-hover check, if one is pending.
    private var showOnHoverTask: Task<Void, Never>?

    /// An identifier for the current show-on-hover task.
    private var showOnHoverTaskID = UUID()

    // MARK: Monitors

    /// Monitor for mouse down events.
    private(set) lazy var mouseDownMonitor = UniversalEventMonitor(
        mask: [.leftMouseDown, .rightMouseDown]
    ) { [weak self] event in
        guard let self else {
            return event
        }
        switch event.type {
        case .leftMouseDown:
            handleShowOnClick()
            handleSmartRehide(with: event)
        case .rightMouseDown:
            handleShowRightClickMenu()
        default:
            break
        }
        handlePreventShowOnHover(with: event)
        return event
    }

    /// Monitor for mouse up events.
    private(set) lazy var mouseUpMonitor = UniversalEventMonitor(
        mask: .leftMouseUp
    ) { [weak self] event in
        self?.handleLeftMouseUp()
        return event
    }

    /// Monitor for mouse dragged events.
    private(set) lazy var mouseDraggedMonitor = UniversalEventMonitor(
        mask: .leftMouseDragged
    ) { [weak self] event in
        self?.handleLeftMouseDragged(with: event)
        return event
    }

    /// Monitor for mouse moved events.
    private(set) lazy var mouseMovedMonitor = UniversalEventMonitor(
        mask: .mouseMoved
    ) { [weak self] event in
        self?.handleShowOnHover()
        return event
    }

    /// Monitor for scroll wheel events.
    private(set) lazy var scrollWheelMonitor = UniversalEventMonitor(
        mask: .scrollWheel
    ) { [weak self] event in
        self?.handleShowOnScroll(with: event)
        return event
    }

    // MARK: All Monitors

    /// All monitors maintained by the app.
    private lazy var allMonitors = [
        mouseDownMonitor,
        mouseUpMonitor,
        mouseDraggedMonitor,
        mouseMovedMonitor,
        scrollWheelMonitor,
    ]

    // MARK: Initializers

    /// Creates an event manager with the given app state.
    init(appState: AppState) {
        self.appState = appState
    }

    /// Sets up the manager.
    func performSetup() {
        configureCancellables()
        startAll()
    }

    /// Configures the internal observers for the manager.
    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        if let appState {
            // Only run the monitors that the current settings need. Global monitors for
            // high-frequency events (mouse moved, dragged, scroll wheel) wake the app for
            // every event the user produces, even when the handlers return immediately.
            Publishers.Merge4(
                appState.settingsManager.generalSettingsManager.$showOnHover.mapToVoid(),
                appState.settingsManager.generalSettingsManager.$showOnScroll.mapToVoid(),
                appState.settingsManager.advancedSettingsManager.$showAllSectionsOnUserDrag.mapToVoid(),
                appState.appearanceManager.$configuration.mapToVoid()
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.updateMonitors()
            }
            .store(in: &c)

            if let hiddenSection = appState.menuBarManager.section(withName: .hidden) {
                // In fullscreen mode, the menu bar slides down from the top on hover. Observe
                // the frame of the hidden section's control item, which we know will always be
                // in the menu bar, and run the show-on-hover check when it changes.
                Publishers.CombineLatest(
                    hiddenSection.controlItem.$windowFrame,
                    appState.$isActiveSpaceFullscreen
                )
                .sink { [weak self] _, isFullscreen in
                    guard
                        let self,
                        isFullscreen
                    else {
                        return
                    }
                    handleShowOnHover()
                }
                .store(in: &c)
            }
        }

        cancellables = c
    }

    // MARK: Start/Stop

    /// Returns a Boolean value that indicates whether the given monitor is
    /// needed by the current settings.
    private func isMonitorNeeded(_ monitor: UniversalEventMonitor) -> Bool {
        guard let appState else {
            return false
        }
        let generalSettings = appState.settingsManager.generalSettingsManager
        let advancedSettings = appState.settingsManager.advancedSettingsManager
        if monitor === mouseMovedMonitor {
            return generalSettings.showOnHover
        }
        if monitor === scrollWheelMonitor {
            return generalSettings.showOnScroll
        }
        if monitor === mouseDraggedMonitor || monitor === mouseUpMonitor {
            // Dragging is used to show all sections and to fade out the overlay panels.
            return advancedSettings.showAllSectionsOnUserDrag ||
                appState.appearanceManager.mayNeedOverlayPanels(for: appState.appearanceManager.configuration)
        }
        return true
    }

    /// Starts or stops each monitor according to the current settings.
    private func updateMonitors() {
        for monitor in allMonitors {
            if isRunning && isMonitorNeeded(monitor) {
                monitor.start()
            } else {
                monitor.stop()
            }
        }
        if !isRunning || !isMonitorNeeded(mouseUpMonitor) {
            // The mouse up event that ends a drag can't be received while the
            // monitor is stopped, so make sure the overlay panels don't stay faded.
            appState?.appearanceManager.setIsDraggingMenuBarItem(false)
        }
        if !isRunning || !isMonitorNeeded(mouseMovedMonitor) {
            showOnHoverTask?.cancel()
            showOnHoverTask = nil
            showOnHoverTaskID = UUID()
        }
    }

    /// Starts all monitors needed by the current settings.
    func startAll() {
        isRunning = true
        updateMonitors()
    }

    /// Stops all monitors.
    func stopAll() {
        isRunning = false
        updateMonitors()
    }
}

// MARK: - Handlers

extension EventManager {

    // MARK: Handle Show On Click

    private func handleShowOnClick() {
        guard
            let appState,
            appState.settingsManager.generalSettingsManager.showOnClick,
            isMouseInsideEmptyMenuBarSpace
        else {
            return
        }

        Task {
            // Short delay helps the toggle action feel more natural.
            try? await Task.sleep(for: .milliseconds(50))

            if NSEvent.modifierFlags == .control {
                handleShowRightClickMenu()
            } else if
                NSEvent.modifierFlags == .option,
                appState.settingsManager.advancedSettingsManager.canToggleAlwaysHiddenSection
            {
                if let alwaysHiddenSection = appState.menuBarManager.section(withName: .alwaysHidden) {
                    alwaysHiddenSection.toggle()
                }
            } else {
                if let hiddenSection = appState.menuBarManager.section(withName: .hidden) {
                    hiddenSection.toggle()
                }
            }
        }
    }

    // MARK: Handle Smart Rehide

    private func handleSmartRehide(with event: NSEvent) {
        guard
            let appState,
            appState.settingsManager.generalSettingsManager.autoRehide,
            case .smart = appState.settingsManager.generalSettingsManager.rehideStrategy
        else {
            return
        }

        if let visibleSection = appState.menuBarManager.section(withName: .visible) {
            guard event.window !== visibleSection.controlItem.window else {
                return
            }
        }

        // Make sure clicking the Ice Bar doesn't trigger rehide.
        guard event.window !== appState.menuBarManager.iceBarPanel else {
            return
        }

        // Only continue if a section is currently visible.
        guard appState.menuBarManager.sections.contains(where: { !$0.isHidden }) else {
            return
        }

        // Make sure the mouse is not in the menu bar.
        guard !isMouseInsideMenuBar else {
            return
        }

        Task {
            let initialSpaceID = Bridging.activeSpaceID

            // Sleep for a bit to give the window under the mouse a chance to focus.
            try? await Task.sleep(for: .seconds(0.25))

            // If clicking caused a space change, don't bother with the window check.
            if Bridging.activeSpaceID != initialSpaceID {
                for section in appState.menuBarManager.sections {
                    section.hide()
                }
                return
            }

            // Get the window that the user has clicked into.
            guard
                let mouseLocation = MouseCursor.locationCoreGraphics,
                let windowUnderMouse = WindowInfo.getOnScreenWindows(excludeDesktopWindows: false)
                    .filter({ $0.layer < CGWindowLevelForKey(.cursorWindow) })
                    .first(where: { $0.frame.contains(mouseLocation) && $0.title?.isEmpty == false }),
                let owningApplication = windowUnderMouse.owningApplication
            else {
                return
            }

            // The dock is an exception to the following check.
            if owningApplication.bundleIdentifier != "com.apple.dock" {
                // Only continue if the user has clicked into an active window with
                // a regular activation policy.
                guard
                    owningApplication.isActive,
                    owningApplication.activationPolicy == .regular
                else {
                    return
                }
            }

            // If all the above checks have passed, hide all sections.
            for section in appState.menuBarManager.sections {
                section.hide()
            }
        }
    }

    // MARK: Handle Show Right Click Menu

    private func handleShowRightClickMenu() {
        guard
            let appState,
            appState.settingsManager.advancedSettingsManager.showContextMenuOnRightClick,
            isMouseInsideEmptyMenuBarSpace,
            let mouseLocation = MouseCursor.locationAppKit
        else {
            return
        }
        appState.menuBarManager.showRightClickMenu(at: mouseLocation)
    }

    // MARK: Handle Prevent Show On Hover

    private func handlePreventShowOnHover(with event: NSEvent) {
        guard
            let appState,
            appState.settingsManager.generalSettingsManager.showOnHover,
            !appState.settingsManager.generalSettingsManager.useIceBar,
            isMouseInsideMenuBar
        else {
            return
        }

        if isMouseInsideMenuBarItem {
            switch event.type {
            case .leftMouseDown:
                if appState.menuBarManager.sections.contains(where: { !$0.isHidden }) || isMouseInsideIceIcon {
                    // We have a left click that is inside the menu bar while at least one
                    // section is visible or the mouse is inside the Ice icon.
                    appState.preventShowOnHover()
                }
            case .rightMouseDown:
                if appState.menuBarManager.sections.contains(where: { !$0.isHidden }) {
                    // We have a right click that is inside the menu bar while at least one
                    // section is visible.
                    appState.preventShowOnHover()
                }
            default:
                break
            }
        } else if !isMouseInsideApplicationMenu {
            // We have a left or right click that is inside the menu bar, outside
            // a menu bar item, and outside the application menu, so it _must_ be
            // inside an empty menu bar space.
            appState.preventShowOnHover()
        }
    }

    // MARK: Handle Left Mouse Up

    private func handleLeftMouseUp() {
        guard let appearanceManager = appState?.appearanceManager else {
            return
        }
        appearanceManager.setIsDraggingMenuBarItem(false)
    }

    // MARK: Handle Left Mouse Dragged

    private func handleLeftMouseDragged(with event: NSEvent) {
        guard
            let appState,
            event.modifierFlags.contains(.command),
            isMouseInsideMenuBar
        else {
            return
        }

        // Notify each overlay panel that a menu bar item is being dragged.
        appState.appearanceManager.setIsDraggingMenuBarItem(true)

        // Don't continue if the setting to show the sections is disabled.
        guard appState.settingsManager.advancedSettingsManager.showAllSectionsOnUserDrag else {
            return
        }

        // Show all items, including section dividers.
        for section in appState.menuBarManager.sections {
            section.controlItem.state = .showItems
            guard
                section.controlItem.isSectionDivider,
                !section.controlItem.isVisible
            else {
                continue
            }
            section.controlItem.isVisible = true
        }
    }

    // MARK: Handle Show On Hover

    private func handleShowOnHover() {
        guard let appState else {
            return
        }

        // Make sure the "ShowOnHover" feature is enabled and not prevented.
        guard
            appState.settingsManager.generalSettingsManager.showOnHover,
            !appState.isShowOnHoverPrevented
        else {
            return
        }

        // Only continue if we have a hidden section (we should).
        guard let hiddenSection = appState.menuBarManager.section(withName: .hidden) else {
            return
        }

        // Mouse moved events arrive at the pointer's polling rate. Only keep a single
        // check pending at a time, rather than spawning a task for every event.
        guard showOnHoverTask == nil else {
            return
        }

        let isHidden = hiddenSection.isHidden

        // Perform the cheap geometric checks up front. The checks that query the
        // window server and the Accessibility API only run once the delay ends.
        if isHidden {
            guard
                isMouseInsideMenuBar,
                !isMouseInsideNotch
            else {
                return
            }
        } else {
            guard
                !isMouseInsideMenuBar,
                !isMouseInsideIceBar
            else {
                return
            }
        }

        let delay = appState.settingsManager.advancedSettingsManager.showOnHoverDelay
        let taskID = UUID()

        showOnHoverTaskID = taskID
        showOnHoverTask = Task { [weak self, weak appState] in
            defer {
                if self?.showOnHoverTaskID == taskID {
                    self?.showOnHoverTask = nil
                }
            }
            // Make sure the mouse starts out inside an empty menu bar space, so that
            // the delay is measured from when it entered the space. If it doesn't,
            // wait briefly before allowing another check, as the check is expensive
            // and the mouse is likely still moving over the application menu or items.
            if isHidden {
                guard self?.isMouseInsideEmptyMenuBarSpace == true else {
                    try? await Task.sleep(for: .milliseconds(50))
                    return
                }
            }
            try? await Task.sleep(for: .seconds(delay))
            guard
                let self,
                let appState,
                !Task.isCancelled,
                !appState.isShowOnHoverPrevented,
                hiddenSection.isHidden == isHidden
            else {
                return
            }
            if isHidden {
                // Make sure the mouse is inside an empty menu bar space.
                guard isMouseInsideEmptyMenuBarSpace else {
                    return
                }
                hiddenSection.show()
            } else {
                // Make sure the mouse is still outside.
                guard
                    !isMouseInsideMenuBar,
                    !isMouseInsideIceBar
                else {
                    return
                }
                hiddenSection.hide()
            }
        }
    }

    // MARK: Handle Show On Scroll

    private func handleShowOnScroll(with event: NSEvent) {
        guard let appState else {
            return
        }

        // Make sure the "ShowOnScroll" feature is enabled.
        guard appState.settingsManager.generalSettingsManager.showOnScroll else {
            return
        }

        // Make sure the mouse is inside the menu bar.
        guard isMouseInsideMenuBar else {
            return
        }

        // Only continue if we have a hidden section (we should).
        guard let hiddenSection = appState.menuBarManager.section(withName: .hidden) else {
            return
        }

        let averageDelta = (event.scrollingDeltaX + event.scrollingDeltaY) / 2

        if averageDelta > 5 {
            hiddenSection.show()
        } else if averageDelta < -5 {
            hiddenSection.hide()
        }
    }
}

// MARK: - Helpers

extension EventManager {
    /// An upper bound for the height of the menu bar, used to skip expensive
    /// checks when the mouse is clearly outside of the menu bar.
    private static let maxMenuBarHeight: CGFloat = 64

    /// Returns the best screen to use for event manager calculations.
    var bestScreen: NSScreen? {
        guard let appState else {
            return nil
        }
        if appState.isActiveSpaceFullscreen {
            return NSScreen.screenWithMouse ?? NSScreen.main
        } else {
            return NSScreen.main
        }
    }

    /// A Boolean value that indicates whether the mouse pointer is within
    /// the bounds of the menu bar.
    var isMouseInsideMenuBar: Bool {
        guard
            let screen = bestScreen,
            let appState
        else {
            return false
        }
        if appState.menuBarManager.isMenuBarHiddenBySystem || appState.isActiveSpaceFullscreen {
            // The menu bar can only ever be at the top of the screen. Avoid copying the
            // window list (which is expensive, and can happen for every mouse event) if
            // the mouse is clearly outside of that area.
            guard
                let mouseLocationAppKit = MouseCursor.locationAppKit,
                screen.frame.maxY - mouseLocationAppKit.y <= Self.maxMenuBarHeight
            else {
                return false
            }
            if
                let mouseLocation = MouseCursor.locationCoreGraphics,
                let menuBarWindow = WindowInfo.getMenuBarWindow(for: screen.displayID)
            {
                return menuBarWindow.frame.contains(mouseLocation)
            }
        } else if let mouseLocation = MouseCursor.locationAppKit {
            return mouseLocation.y > screen.visibleFrame.maxY && mouseLocation.y <= screen.frame.maxY
        }
        return false
    }

    /// A Boolean value that indicates whether the mouse pointer is within
    /// the bounds of the current application menu.
    var isMouseInsideApplicationMenu: Bool {
        guard
            let mouseLocation = MouseCursor.locationCoreGraphics,
            let screen = bestScreen,
            let appState,
            var applicationMenuFrame = appState.menuBarManager.getApplicationMenuFrame(for: screen.displayID)
        else {
            return false
        }
        applicationMenuFrame.size.width += applicationMenuFrame.origin.x - screen.frame.origin.x
        applicationMenuFrame.origin.x = screen.frame.origin.x
        return applicationMenuFrame.contains(mouseLocation)
    }

    /// A Boolean value that indicates whether the mouse pointer is within
    /// the bounds of a menu bar item.
    var isMouseInsideMenuBarItem: Bool {
        guard
            let screen = bestScreen,
            let mouseLocation = MouseCursor.locationCoreGraphics
        else {
            return false
        }
        let menuBarItems = MenuBarItem.getMenuBarItems(on: screen.displayID, onScreenOnly: true, activeSpaceOnly: true)
        return menuBarItems.contains { $0.frame.contains(mouseLocation) }
    }

    /// A Boolean value that indicates whether the mouse pointer is within
    /// the bounds of the screen's notch, if it has one.
    ///
    /// If the screen returned from ``bestScreen`` does not have a notch,
    /// this property returns `false`.
    var isMouseInsideNotch: Bool {
        guard
            let screen = bestScreen,
            let mouseLocation = MouseCursor.locationAppKit,
            let frameOfNotch = screen.frameOfNotch
        else {
            return false
        }
        return frameOfNotch.contains(mouseLocation)
    }

    /// A Boolean value that indicates whether the mouse pointer is within
    /// the bounds of an empty space in the menu bar.
    var isMouseInsideEmptyMenuBarSpace: Bool {
        // Perform the cheap geometric checks before the ones that query the
        // window server and the Accessibility API.
        isMouseInsideMenuBar &&
        !isMouseInsideNotch &&
        !isMouseInsideApplicationMenu &&
        !isMouseInsideMenuBarItem
    }

    /// A Boolean value that indicates whether the mouse pointer is within
    /// the bounds of the Ice Bar panel.
    var isMouseInsideIceBar: Bool {
        guard
            let appState,
            let mouseLocation = MouseCursor.locationAppKit
        else {
            return false
        }
        let panel = appState.menuBarManager.iceBarPanel
        // Pad the frame to be more forgiving if the user accidentally
        // moves their mouse outside of the Ice Bar.
        let paddedFrame = panel.frame.insetBy(dx: -10, dy: -10)
        return paddedFrame.contains(mouseLocation)
    }

    /// A Boolean value that indicates whether the mouse pointer is within
    /// the bounds of the Ice icon.
    var isMouseInsideIceIcon: Bool {
        guard
            let appState,
            let visibleSection = appState.menuBarManager.section(withName: .visible),
            let iceIconFrame = visibleSection.controlItem.windowFrame,
            let mouseLocation = MouseCursor.locationAppKit
        else {
            return false
        }
        return iceIconFrame.contains(mouseLocation)
    }
}

// MARK: - Logger
private extension Logger {
    static let eventManager = Logger(category: "EventManager")
}
