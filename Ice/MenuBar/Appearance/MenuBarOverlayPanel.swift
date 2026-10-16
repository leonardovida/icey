//
//  MenuBarOverlayPanel.swift
//  Ice
//

import Cocoa
import Combine
import OSLog

// MARK: - Overlay Panel

/// A subclass of `NSPanel` that sits atop the menu bar to alter its appearance.
final class MenuBarOverlayPanel: NSPanel {
    /// Flags representing the updatable components of a panel.
    enum UpdateFlag: String, CustomStringConvertible {
        case applicationMenuFrame
        case desktopWallpaper

        var description: String { rawValue }
    }

    /// The kind of validation that occurs before an update.
    private enum ValidationKind {
        case showing
        case updates
    }

    /// A context that manages panel update tasks.
    private final class UpdateTaskContext {
        private var tasks = [UpdateFlag: Task<Void, any Error>]()

        /// Sets the task for the given update flag.
        ///
        /// Setting the task cancels the previous task for the flag, if there is one.
        ///
        /// - Parameters:
        ///   - flag: The update flag to set the task for.
        ///   - timeout: The timeout of the task.
        ///   - operation: The operation for the task to perform.
        func setTask(for flag: UpdateFlag, timeout: Duration, operation: @escaping () async throws -> Void) {
            cancelTask(for: flag)
            tasks[flag] = Task.detached(timeout: timeout) {
                try await operation()
            }
        }

        /// Cancels the task for the given update flag.
        ///
        /// - Parameter flag: The update flag to cancel the task for.
        func cancelTask(for flag: UpdateFlag) {
            tasks.removeValue(forKey: flag)?.cancel()
        }
    }

    /// Shared logger for overlay panels.
    private static let logger = Logger(category: "MenuBarOverlayPanel")

    /// A Boolean value that indicates whether the panel needs to be shown.
    @Published var needsShow = false

    /// Flags representing the components of the panel currently in need of an update.
    @Published private(set) var updateFlags = Set<UpdateFlag>()

    /// The frame of the application menu.
    @Published private(set) var applicationMenuFrame: CGRect?

    /// The current desktop wallpaper, clipped to the bounds of the menu bar.
    @Published private(set) var desktopWallpaper: CGImage?

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// The context that manages panel update tasks.
    private let updateTaskContext = UpdateTaskContext()

    /// The task that tries to show the panel again after its display had no
    /// menu bar to show over.
    private var showRetryTask: Task<Void, Never>?

    /// The number of times in a row the panel has tried to show again.
    private var showRetryCount = 0

    /// The number of times in a row the panel has waited for Mission Control
    /// to close. After about two minutes it shows regardless, so that a window
    /// mistaken for Mission Control cannot keep it away.
    private var missionControlWaitCount = 0

    /// The last answer to whether Mission Control is open, shared by the
    /// panels on every display so they ask the window server once per check.
    private static var missionControlCheck: (date: Date, isActive: Bool)?

    /// The shared app state.
    private(set) weak var appState: AppState?

    /// The screen that owns the panel.
    let owningScreen: NSScreen

    /// Creates an overlay panel with the given app state and owning screen.
    init(appState: AppState, owningScreen: NSScreen) {
        self.appState = appState
        self.owningScreen = owningScreen
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.level = .statusBar
        self.title = "Menu Bar Overlay"
        self.backgroundColor = .clear
        self.hasShadow = false
        self.animationBehavior = .none
        self.hidesOnDeactivate = false
        self.canHide = false
        self.isMovable = false
        self.ignoresMouseEvents = true
        self.isExcludedFromWindowsMenu = true
        self.collectionBehavior = [.fullScreenNone, .ignoresCycle, .moveToActiveSpace]
        self.contentView = MenuBarOverlayPanelContentView()
        configureCancellables()
    }

    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        // Show the panel on the active space, and again when the displays wake,
        // as the menu bar may not have been back when a display change during
        // sleep rebuilt the panels (jordanbaird/Ice#53).
        Publishers.Merge(
            NSWorkspace.shared.notificationCenter
                .publisher(for: NSWorkspace.activeSpaceDidChangeNotification),
            NSWorkspace.shared.notificationCenter
                .publisher(for: NSWorkspace.screensDidWakeNotification)
        )
        .debounce(for: 0.1, scheduler: DispatchQueue.main)
        .sink { [weak self] _ in
            guard let self else {
                return
            }
            // A fresh request gets a fresh set of retries, so retries used up
            // while the displays slept don't stop the panel showing on wake.
            showRetryCount = 0
            needsShow = true
        }
        .store(in: &c)

        // Update when light/dark mode changes.
        DistributedNotificationCenter.default()
            .publisher(for: DistributedNotificationCenter.interfaceThemeChangedNotification)
            .debounce(for: 0.1, scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, needsDesktopWallpaper else {
                    return
                }
                updateTaskContext.setTask(for: .desktopWallpaper, timeout: .seconds(5)) {
                    while true {
                        try Task.checkCancellation()
                        self.insertUpdateFlag(.desktopWallpaper)
                        try await Task.sleep(for: .seconds(1))
                    }
                }
            }
            .store(in: &c)

        // Update application menu frame when the menu bar owning or frontmost app changes.
        Publishers.Merge(
            NSWorkspace.shared.publisher(for: \.menuBarOwningApplication, options: .old)
                .combineLatest(NSWorkspace.shared.publisher(for: \.menuBarOwningApplication, options: .new))
                .compactMap { $0 == $1 ? nil : $0 },
            NSWorkspace.shared.publisher(for: \.frontmostApplication, options: .old)
                .combineLatest(NSWorkspace.shared.publisher(for: \.frontmostApplication, options: .new))
                .compactMap { $0 == $1 ? nil : $0 }
        )
        .removeDuplicates()
        .sink { [weak self] _ in
            guard let self, needsApplicationMenuFrame else {
                return
            }
            updateTaskContext.setTask(for: .applicationMenuFrame, timeout: .seconds(10)) {
                // Apps can take some time to populate their menus after they launch, so
                // keep checking for a while. Each check makes several Accessibility calls,
                // so back off instead of polling in a tight loop, which is especially
                // costly when the frame doesn't change or can't be retrieved.
                var interval = Duration.milliseconds(10)
                while true {
                    try Task.checkCancellation()
                    if
                        let latestFrame = self.owningScreen.getApplicationMenuFrame(),
                        latestFrame != self.applicationMenuFrame
                    {
                        self.insertUpdateFlag(.applicationMenuFrame)
                    }
                    try await Task.sleep(for: interval)
                    interval = min(interval * 2, .seconds(1))
                }
            }
            Task {
                try? await Task.sleep(for: .milliseconds(100))
                if self.owningScreen != NSScreen.main {
                    self.updateTaskContext.cancelTask(for: .applicationMenuFrame)
                }
            }
        }
        .store(in: &c)

        // Special cases for when the user drags an app onto or clicks into another space.
        Publishers.Merge(
            publisher(for: \.isOnActiveSpace)
                .receive(on: DispatchQueue.main)
                .replace(with: ()),
            EventMonitor.publish(events: .leftMouseUp, scope: .universal)
                .filter { [weak self] _ in self?.isOnActiveSpace ?? false }
                .replace(with: ())
        )
        .debounce(for: 0.05, scheduler: DispatchQueue.main)
        .sink { [weak self] in
            guard let self, needsApplicationMenuFrame else {
                return
            }
            insertUpdateFlag(.applicationMenuFrame)
        }
        .store(in: &c)

        // The desktop wallpaper and application menu frame are also updated
        // periodically, by one timer for the panels on every display (see
        // `MenuBarAppearanceManager.performPeriodicOverlayPanelUpdates()`).

        // The panel belongs to one display. If the window server moves it to
        // another one, take it off screen rather than draw that display's
        // tint and shape across someone else's (see `orderOutIfOnOtherDisplay()`).
        NotificationCenter.default
            .publisher(for: NSWindow.didChangeScreenNotification, object: self)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.orderOutIfOnOtherDisplay()
            }
            .store(in: &c)

        $needsShow
            .debounce(for: 0.05, scheduler: DispatchQueue.main)
            .sink { [weak self] needsShow in
                guard let self, needsShow else {
                    return
                }
                defer {
                    self.needsShow = false
                }
                show()
            }
            .store(in: &c)

        $updateFlags
            .sink { [weak self] flags in
                guard let self, !flags.isEmpty else {
                    return
                }
                Task {
                    // Must be run async, or this will not remove the flags.
                    self.updateFlags.removeAll()
                }
                let windows = WindowInfo.createWindows(option: .onScreen)
                if validate(for: .updates, with: windows) {
                    performUpdates(for: flags, windows: windows, screen: owningScreen)
                }
            }
            .store(in: &c)

        if let appState {
            appState.menuBarManager.$isMenuBarHiddenBySystem
                .sink { [weak self] isHidden in
                    guard let self else {
                        return
                    }
                    // The presentation options follow the frontmost app, which
                    // can be on another display. Leaving a fullscreen app there
                    // must not reveal this panel over a fullscreen space here.
                    alphaValue = isHidden || isOwningDisplayFullscreen ? 0 : 1
                }
                .store(in: &c)

            // The desktop wallpaper and application menu frame are only needed for
            // some shapes, so update them when the shape changes. Receive on the main
            // queue, as the publisher emits before the new configuration is stored.
            appState.appearanceManager.$configuration
                .map(\.shapeKind)
                .removeDuplicates()
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.updateFlags.formUnion([.applicationMenuFrame, .desktopWallpaper])
                }
                .store(in: &c)
        }

        cancellables = c
    }

    /// A Boolean value that indicates whether the space currently shown on the
    /// panel's owning display is fullscreen.
    ///
    /// The active space is the one on the display with keyboard focus, so with
    /// separate spaces per display it says nothing about the other displays: a
    /// fullscreen app on one display stopped the panels of every display from
    /// updating, while the panel of the fullscreen display was shown again as
    /// soon as focus moved to a desktop elsewhere. Falls back to the active
    /// space when the display has no space of its own (spaces span displays).
    private var isOwningDisplayFullscreen: Bool {
        if
            let space = SpaceInfo.currentSpace(for: owningScreen.displayID),
            space.spaceID != 0
        {
            return space.isFullscreen
        }
        return appState?.activeSpace.isFullscreen ?? false
    }

    /// A Boolean value that indicates whether the panel needs the frame of the
    /// application menu, which is only used to draw the split shape.
    private var needsApplicationMenuFrame: Bool {
        appState?.appearanceManager.configuration.shapeKind == .split
    }

    /// A Boolean value that indicates whether the panel needs the desktop
    /// wallpaper, which is only drawn for the full and split shapes.
    private var needsDesktopWallpaper: Bool {
        guard let shapeKind = appState?.appearanceManager.configuration.shapeKind else {
            return false
        }
        return shapeKind != .noShape
    }

    /// Inserts the given update flag into the panel's current list of update flags.
    private func insertUpdateFlag(_ flag: UpdateFlag) {
        updateFlags.insert(flag)
    }

    /// Performs validation for the given validation kind. Returns the panel's
    /// owning display if successful. Returns `nil` on failure.
    private func validate(for kind: ValidationKind, with windows: [WindowInfo]) -> Bool {
        lazy var actionMessage = switch kind {
        case .showing: "Preventing overlay panel from showing."
        case .updates: "Preventing overlay panel from updating."
        }
        guard let appState else {
            MenuBarOverlayPanel.logger.debug("No app state. \(actionMessage, privacy: .public)")
            return false
        }
        guard !isOwningDisplayFullscreen else {
            MenuBarOverlayPanel.logger.debug("Space on owning display is fullscreen. \(actionMessage, privacy: .public)")
            return false
        }
        guard appState.menuBarManager.hasValidMenuBar(in: windows, for: owningScreen.displayID) else {
            MenuBarOverlayPanel.logger.debug("No valid menu bar found. \(actionMessage, privacy: .public)")
            return false
        }
        return true
    }

    /// Stores the frame of the menu bar's application menu.
    private func updateApplicationMenuFrame(for screen: NSScreen) {
        guard
            let menuBarManager = appState?.menuBarManager,
            !menuBarManager.isMenuBarHiddenBySystem,
            needsApplicationMenuFrame
        else {
            return
        }
        // Accessibility describes the menus of the display with the active menu
        // bar, while every other display keeps drawing the menus of the app last
        // active on it. Read from another display, the frame is the active
        // display's menus, or nil when they reach past this display's notch, and
        // nil collapsed the split shape into one continuous shape whenever focus
        // moved to another display. Keep the frame measured while this display
        // was active; only fill it in from elsewhere when there is none yet.
        if
            applicationMenuFrame != nil,
            let activeScreen = NSScreen.screenWithActiveMenuBar ?? NSScreen.main,
            activeScreen != screen
        {
            return
        }
        applicationMenuFrame = screen.getApplicationMenuFrame()
    }

    /// Stores the area of the desktop wallpaper that is under the menu bar
    /// of the given display.
    private func updateDesktopWallpaper(for display: CGDirectDisplayID, with windows: [WindowInfo]) {
        // Capturing the wallpaper is expensive (and grows the window server's
        // memory), so skip it for shapes that don't draw it.
        guard needsDesktopWallpaper else {
            if desktopWallpaper != nil {
                desktopWallpaper = nil
            }
            return
        }
        // Don't capture while the display is asleep.
        guard CGDisplayIsAsleep(display) == 0 else {
            return
        }
        guard
            let wallpaperWindow = WindowInfo.wallpaperWindow(from: windows, for: display),
            let menuBarWindow = WindowInfo.menuBarWindow(from: windows, for: display)
        else {
            return
        }
        // The wallpaper is drawn around the shape, so it has to look the way the
        // desktop looks there. On macOS 26 that includes the window that darkens
        // the wallpaper behind the menu bar, which is above the wallpaper window.
        // Drawing the wallpaper without it made everything outside the shape
        // brighter than the desktop below the menu bar (jordanbaird/Ice#943).
        var windowIDs = [wallpaperWindow.windowID]
        if
            #unavailable(macOS 27.0),
            let underbellyWindow = WindowInfo.menuBarUnderbellyWindow(from: windows, for: display)
        {
            windowIDs.insert(underbellyWindow.windowID, at: 0) // Front to back.
        }
        let wallpaper = ScreenCapture.captureWindows(with: windowIDs, screenBounds: menuBarWindow.bounds)
        if desktopWallpaper?.dataProvider?.data != wallpaper?.dataProvider?.data {
            desktopWallpaper = wallpaper
        }
    }

    /// Returns the flags among the given ones that the panel needs updated
    /// periodically with its current configuration.
    func periodicUpdateFlags(from flags: Set<UpdateFlag>) -> Set<UpdateFlag> {
        flags.filter { flag in
            switch flag {
            case .applicationMenuFrame: needsApplicationMenuFrame
            case .desktopWallpaper: needsDesktopWallpaper
            }
        }
    }

    /// Performs a periodic update of the given flags, with a list of on
    /// screen windows taken once for the panels on every display.
    ///
    /// Each panel used to run its own timers, one for the wallpaper and one
    /// for the application menu frame, and each update took its own window
    /// list. The appearance manager now drives them from one timer.
    func performPeriodicUpdates(for flags: Set<UpdateFlag>, windows: [WindowInfo]) {
        let flags = periodicUpdateFlags(from: flags)
        guard
            !flags.isEmpty,
            validate(for: .updates, with: windows)
        else {
            return
        }
        performUpdates(for: flags, windows: windows, screen: owningScreen)
    }

    /// Updates the panel to prepare for display.
    private func performUpdates(for flags: Set<UpdateFlag>, windows: [WindowInfo], screen: NSScreen) {
        if flags.contains(.applicationMenuFrame) {
            updateApplicationMenuFrame(for: screen)
        }
        if flags.contains(.desktopWallpaper) {
            updateDesktopWallpaper(for: screen.displayID, with: windows)
        }
    }

    /// Shows the panel.
    private func show() {
        guard let appState else {
            return
        }

        guard appState.appearanceManager.overlayPanels.contains(self) else {
            MenuBarOverlayPanel.logger.warning("Overlay panel \(self) not retained")
            return
        }

        // Ordering the panel front pulls it onto the space now shown on its
        // display, fullscreen ones included, where it drew the desktop wallpaper
        // around the menu bar shape instead of the fullscreen app's black bar.
        // Updates were already refused there; showing was not.
        guard !isOwningDisplayFullscreen else {
            MenuBarOverlayPanel.logger.debug("Space on owning display is fullscreen. Preventing overlay panel from showing.")
            alphaValue = 0
            return
        }

        // Mission Control is drawn below the menu bar's level, and a panel
        // ordered front while it is open is drawn above it. The space changes
        // inside Mission Control, when a space is deleted or the user swipes to
        // another one, so the panel was put over the space switcher
        // (jordanbaird/Ice#216). Its wallpaper was also captured then, from
        // windows still on their way in or out (jordanbaird/Ice#337). Wait for
        // Mission Control to close.
        if
            missionControlWaitCount < 60,
            Self.isMissionControlActive()
        {
            missionControlWaitCount += 1
            scheduleShowAfterMissionControl()
            return
        }
        missionControlWaitCount = 0

        guard let menuBarHeight = owningScreen.getMenuBarHeight() else {
            scheduleShowRetry()
            return
        }

        showRetryTask?.cancel()
        showRetryTask = nil
        showRetryCount = 0

        let newFrame = CGRect(
            x: owningScreen.frame.minX,
            y: (owningScreen.frame.maxY - menuBarHeight) - 5,
            width: owningScreen.frame.width,
            height: menuBarHeight + 5
        )

        alphaValue = 0
        setFrame(newFrame, display: false)
        orderFrontRegardless()

        if orderOutIfOnOtherDisplay() {
            return
        }

        updateFlags = [.applicationMenuFrame, .desktopWallpaper]

        // The panel is shown a moment after the space changes, while the
        // switch can still be animating, and the wallpaper captured then was
        // otherwise kept until the next periodic capture, five seconds later
        // (jordanbaird/Ice#336, #337). Capture it once more when it has settled.
        if needsDesktopWallpaper {
            updateTaskContext.setTask(for: .desktopWallpaper, timeout: .seconds(5)) {
                try await Task.sleep(for: .seconds(1))
                // The task is detached, and the update flags drive the
                // panel's updates, which belong on the main actor.
                await MainActor.run {
                    self.insertUpdateFlag(.desktopWallpaper)
                }
            }
        }

        if !appState.menuBarManager.isMenuBarHiddenBySystem {
            animator().alphaValue = 1
        }
    }

    override func close() {
        // A closed panel has been replaced, so it must not show again.
        showRetryTask?.cancel()
        showRetryTask = nil
        super.close()
    }

    /// Tries to show the panel again later, backing off between attempts.
    ///
    /// The panel is shown over its display's menu bar window, and gave up when
    /// there was none. Nothing tried again until the next space change, so an
    /// appearance applied while the menu bar was not there yet never showed:
    /// at login, where the border only appeared after Ice was restarted
    /// (jordanbaird/Ice#409), and after the displays changed during sleep,
    /// which rebuilds the panels while the new displays have no menu bar yet
    /// (jordanbaird/Ice#53). Retries stop after about two minutes.
    private func scheduleShowRetry() {
        let maxRetryCount = 16
        guard showRetryCount < maxRetryCount else {
            MenuBarOverlayPanel.logger.notice(
                "No menu bar on display \(self.owningScreen.displayID, privacy: .public). Giving up showing overlay panel."
            )
            return
        }
        let delay = min(Duration.milliseconds(250) * (1 << min(showRetryCount, 6)), .seconds(10))
        showRetryCount += 1
        showRetryTask?.cancel()
        showRetryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else {
                return
            }
            self?.needsShow = true
        }
    }

    /// Returns whether Mission Control is open, asking the window server at
    /// most once every quarter second for all panels together.
    private static func isMissionControlActive() -> Bool {
        if let check = missionControlCheck, Date.now.timeIntervalSince(check.date) < 0.25 {
            return check.isActive
        }
        let isActive = WindowInfo.isMissionControlActive(in: WindowInfo.createWindows(option: .onScreen))
        missionControlCheck = (.now, isActive)
        return isActive
    }

    /// Tries to show the panel again once Mission Control may have closed.
    ///
    /// The wait grows from a quarter second to two seconds, and each try
    /// shares one window list with the other displays' panels (see
    /// ``isMissionControlActive()``). It only runs while Mission Control is
    /// open after a space change, for about two minutes at most (see
    /// ``missionControlWaitCount``).
    private func scheduleShowAfterMissionControl() {
        let delay = min(Duration.milliseconds(250) * (1 << min(missionControlWaitCount, 3)), .seconds(2))
        showRetryTask?.cancel()
        showRetryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else {
                return
            }
            self?.needsShow = true
        }
    }

    /// Takes the panel off screen if it is on a display other than its owning
    /// display, and returns whether it did.
    ///
    /// The panel is ordered front on the active space, which belongs to the
    /// display with keyboard focus. With an iPad extending the desktop through
    /// Sidecar, the iPad's panel turned up as a strip along the bottom edge of
    /// the main display, next to where the iPad is arranged
    /// (jordanbaird/Ice#910). The likely cause is that the window server keeps
    /// a window on its space's display and pulled the panel back onto the main
    /// one, but that is not confirmed. Whatever moves it, a panel drawn for one
    /// display has no business on another.
    @discardableResult
    private func orderOutIfOnOtherDisplay() -> Bool {
        guard
            isVisible,
            let screen,
            screen.displayID != owningScreen.displayID
        else {
            return false
        }
        MenuBarOverlayPanel.logger.notice(
            """
            Overlay panel for display \(self.owningScreen.displayID, privacy: .public) \
            is on display \(screen.displayID, privacy: .public). Ordering it out.
            """
        )
        orderOut(nil)
        return true
    }

    override func isAccessibilityElement() -> Bool {
        return false
    }
}

// MARK: - Content View

private final class MenuBarOverlayPanelContentView: NSView {
    @Published private var fullConfiguration: MenuBarAppearanceConfigurationV2 = .defaultConfiguration

    @Published private var previewConfiguration: MenuBarAppearancePartialConfiguration?

    private var cancellables = Set<AnyCancellable>()

    /// The overlay panel that contains the content view.
    private var overlayPanel: MenuBarOverlayPanel? {
        window as? MenuBarOverlayPanel
    }

    /// The currently displayed configuration.
    private var configuration: MenuBarAppearancePartialConfiguration {
        previewConfiguration ?? fullConfiguration.current
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureCancellables()
    }

    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        if let overlayPanel {
            if let appState = overlayPanel.appState {
                appState.appearanceManager.$configuration
                    .removeDuplicates()
                    .assign(to: &$fullConfiguration)

                appState.appearanceManager.$previewConfiguration
                    .removeDuplicates()
                    .assign(to: &$previewConfiguration)

                // Fade out whenever a menu bar item is being dragged.
                appState.$isDraggingMenuBarItem
                    .removeDuplicates()
                    .sink { [weak self] isDragging in
                        if isDragging {
                            self?.animator().alphaValue = 0
                        } else {
                            self?.animator().alphaValue = 1
                        }
                    }
                    .store(in: &c)

                if #available(macOS 27.0, *) {
                    // Ice's control items stay collapsed on macOS 27, so their frames never
                    // change. Redraw whenever the items are read again instead.
                    appState.itemManager.$itemCache
                        .receive(on: DispatchQueue.main)
                        .sink { [weak self] _ in
                            self?.needsDisplay = true
                        }
                        .store(in: &c)
                }

                for section in appState.menuBarManager.sections {
                    // Redraw whenever the window frame of a control item changes.
                    //
                    // - NOTE: A previous attempt was made to redraw the view when the
                    //   section's `isHidden` property was changed. This would be semantically
                    //   ideal, but the property sometimes changes before the menu bar items
                    //   are actually updated on-screen. Since the view's drawing process relies
                    //   on getting an accurate position of each menu bar item, we need to use
                    //   something that publishes its changes only after the items are updated.
                    section.controlItem.$onScreenFrame
                        .receive(on: DispatchQueue.main)
                        .sink { [weak self] _ in
                            self?.needsDisplay = true
                        }
                        .store(in: &c)
                }
            }

            // Redraw whenever the application menu frame changes.
            overlayPanel.$applicationMenuFrame
                .sink { [weak self] _ in
                    self?.needsDisplay = true
                }
                .store(in: &c)
            // Redraw whenever the desktop wallpaper changes.
            overlayPanel.$desktopWallpaper
                .sink { [weak self] _ in
                    self?.needsDisplay = true
                }
                .store(in: &c)
        }

        // Redraw whenever the configurations change.
        $fullConfiguration.replace(with: ())
            .merge(with: $previewConfiguration.replace(with: ()))
            .sink { [weak self] _ in
                self?.needsDisplay = true
            }
            .store(in: &c)

        cancellables = c
    }

    /// Returns a path in the given rectangle, with the given end caps,
    /// and inset by the given amounts.
    private func shapePath(in rect: CGRect, leadingEndCap: MenuBarEndCap, trailingEndCap: MenuBarEndCap, screen: NSScreen) -> NSBezierPath {
        let insetRect: CGRect = if !screen.hasNotch {
            switch (leadingEndCap, trailingEndCap) {
            case (.square, .square):
                // A shape with square ends fills the menu bar's height, as it
                // does on a notched display. Insetting it by a point at the top
                // and bottom left a strip of wallpaper above and below the full
                // shape, so on a display without a notch it looked a few pixels
                // shorter than the menu bar (jordanbaird/Ice#657). Shapes with
                // a rounded end keep the inset.
                rect
            case (.square, .round):
                CGRect(x: rect.origin.x, y: rect.origin.y + 1, width: rect.width - 1, height: rect.height - 2)
            case (.round, .square):
                CGRect(x: rect.origin.x + 1, y: rect.origin.y + 1, width: rect.width - 1, height: rect.height - 2)
            case (.round, .round):
                CGRect(x: rect.origin.x + 1, y: rect.origin.y + 1, width: rect.width - 2, height: rect.height - 2)
            }
        } else {
            rect
        }

        let shapeBounds = CGRect(
            x: insetRect.minX + insetRect.height / 2,
            y: insetRect.minY,
            width: insetRect.width - insetRect.height,
            height: insetRect.height
        )
        let leadingEndCapBounds = CGRect(
            x: insetRect.minX,
            y: insetRect.minY,
            width: insetRect.height,
            height: insetRect.height
        )
        let trailingEndCapBounds = CGRect(
            x: insetRect.maxX - insetRect.height,
            y: insetRect.minY,
            width: insetRect.height,
            height: insetRect.height
        )

        var path = NSBezierPath(rect: shapeBounds)

        path = switch leadingEndCap {
        case .square: path.union(NSBezierPath(rect: leadingEndCapBounds))
        case .round: path.union(NSBezierPath(ovalIn: leadingEndCapBounds))
        }

        path = switch trailingEndCap {
        case .square: path.union(NSBezierPath(rect: trailingEndCapBounds))
        case .round: path.union(NSBezierPath(ovalIn: trailingEndCapBounds))
        }

        return path
    }

    /// Returns a path for the ``MenuBarShapeKind/full`` shape kind.
    private func pathForFullShape(in rect: CGRect, info: MenuBarFullShapeInfo, isInset: Bool, screen: NSScreen) -> NSBezierPath {
        guard let appearanceManager = overlayPanel?.appState?.appearanceManager else {
            return NSBezierPath()
        }
        var rect = rect
        let shouldInset = isInset && screen.hasNotch
        if shouldInset {
            let insetAmount = appearanceManager.menuBarInsetAmount(forMenuBarHeight: rect.height)
            rect = rect.insetBy(dx: 0, dy: insetAmount)
            if info.leadingEndCap == .round {
                rect.origin.x += insetAmount
                rect.size.width -= insetAmount
            }
            if info.trailingEndCap == .round {
                rect.size.width -= insetAmount
            }
        }
        return shapePath(
            in: rect,
            leadingEndCap: info.leadingEndCap,
            trailingEndCap: info.trailingEndCap,
            screen: screen
        )
    }

    /// Returns the left edge of the menu bar items drawn against the right edge
    /// of the given display, before macOS 27.
    ///
    /// The items sit side by side from the right edge of the display, so the
    /// right half of the split shape runs from the last of them that touches the
    /// next. It used to be as wide as every item window on the display put
    /// together, which counted windows that are not in that row: windows that
    /// overlap, the clock of the display to the left, which reaches a point or
    /// two past its edge, and hidden items pushed off one display that can land
    /// on another. Each left a blank stretch on the left of the right half
    /// (jordanbaird/Ice#608, jordanbaird/Ice#676, jordanbaird/Ice#529). On a
    /// display wider than a section divider can push items, the hidden items
    /// stay on screen, and an expanded divider counted as an item stretched the
    /// right half across them (jordanbaird/Ice#573). The row ends at a gap or
    /// at an expanded divider.
    ///
    /// Returns `nil` if no item reaches the right edge of the display.
    private func itemsLeftEdge(for displayID: CGDirectDisplayID) -> CGFloat? {
        // Item windows sit edge to edge (measured on macOS 26.5). Allow a little
        // for rounding; the gap left by an expanded divider is thousands of points.
        let maxGap: CGFloat = 10
        // A divider is a standard status item while its section is shown. When
        // the section is hidden, macOS caps its length at about 5000 points
        // (measured 5016 on macOS 26.5).
        let minExpandedDividerWidth: CGFloat = 1000
        let dividerTitles: Set<String> = [
            ControlItem.Identifier.hidden.rawValue,
            ControlItem.Identifier.alwaysHidden.rawValue,
        ]

        let itemWindows = MenuBarItem.getMenuBarItemWindows(on: displayID, option: .onScreen)
            .sorted { $0.bounds.maxX > $1.bounds.maxX }

        var leftEdge = CGDisplayBounds(displayID).maxX
        var hasItems = false
        for window in itemWindows {
            let bounds = window.bounds
            guard bounds.maxX >= leftEdge - maxGap else {
                break
            }
            if
                let title = window.title,
                dividerTitles.contains(title),
                bounds.width >= minExpandedDividerWidth
            {
                break
            }
            leftEdge = min(leftEdge, bounds.minX)
            hasItems = true
        }
        return hasItems ? leftEdge : nil
    }

    /// Returns a path for the ``MenuBarShapeKind/split`` shape kind.
    private func pathForSplitShape(in rect: CGRect, info: MenuBarSplitShapeInfo, isInset: Bool, screen: NSScreen) -> NSBezierPath {
        guard let appearanceManager = overlayPanel?.appState?.appearanceManager else {
            return NSBezierPath()
        }
        var rect = rect
        let shouldInset = isInset && screen.hasNotch
        let insetAmount = appearanceManager.menuBarInsetAmount(forMenuBarHeight: rect.height)
        if shouldInset {
            rect = rect.insetBy(dx: 0, dy: insetAmount)
            if info.leading.leadingEndCap == .round {
                rect.origin.x += insetAmount
                rect.size.width -= insetAmount
            }
            if info.trailing.trailingEndCap == .round {
                rect.size.width -= insetAmount
            }
        }
        let leadingPathBounds: CGRect = {
            guard
                var maxX = overlayPanel?.applicationMenuFrame?.width,
                maxX > 0
            else {
                return .zero
            }
            if shouldInset {
                maxX += 10
                if info.leading.leadingEndCap == .square {
                    maxX += insetAmount
                }
            } else {
                maxX += 20
            }
            return CGRect(x: rect.minX, y: rect.minY, width: maxX, height: rect.height)
        }()
        let trailingPathBounds: CGRect = {
            let totalWidth: CGFloat
            if #available(macOS 27.0, *) {
                // Items are no longer windows on macOS 27; they run from the leftmost
                // drawn item to the edge of the display.
                guard let leftEdge = MenuBarItemProvider27.leftEdge(for: screen.displayID) else {
                    return .zero
                }
                totalWidth = CGDisplayBounds(screen.displayID).maxX - leftEdge
            } else {
                guard let leftEdge = itemsLeftEdge(for: screen.displayID) else {
                    return .zero
                }
                totalWidth = CGDisplayBounds(screen.displayID).maxX - leftEdge
            }
            var position = rect.maxX - totalWidth
            if shouldInset {
                position += 4
                if info.trailing.trailingEndCap == .square {
                    position -= insetAmount
                }
            } else {
                position -= 7
            }
            return CGRect(x: position, y: rect.minY, width: rect.maxX - position, height: rect.height)
        }()

        if leadingPathBounds == .zero || trailingPathBounds == .zero || leadingPathBounds.intersects(trailingPathBounds) {
            return shapePath(
                in: rect,
                leadingEndCap: info.leading.leadingEndCap,
                trailingEndCap: info.trailing.trailingEndCap,
                screen: screen
            )
        } else {
            let leadingPath = shapePath(
                in: leadingPathBounds,
                leadingEndCap: info.leading.leadingEndCap,
                trailingEndCap: info.leading.trailingEndCap,
                screen: screen
            )
            let trailingPath = shapePath(
                in: trailingPathBounds,
                leadingEndCap: info.trailing.leadingEndCap,
                trailingEndCap: info.trailing.trailingEndCap,
                screen: screen
            )
            let path = NSBezierPath()
            path.append(leadingPath)
            path.append(trailingPath)
            return path
        }
    }

    /// Returns the bounds that the view's drawn content can occupy.
    private func getDrawableBounds() -> CGRect {
        return CGRect(
            x: bounds.origin.x,
            y: bounds.origin.y + 5,
            width: bounds.width,
            height: bounds.height - 5
        )
    }

    /// Draws the tint defined by the given configuration in the given rectangle.
    private func drawTint(in rect: CGRect) {
        switch configuration.tintKind {
        case .noTint:
            break
        case .solid:
            if let tintColor = NSColor(cgColor: configuration.tintColor)?.withAlphaComponent(0.2) {
                tintColor.setFill()
                rect.fill()
            }
        case .gradient:
            if let tintGradient = configuration.tintGradient.withAlpha(0.2).nsGradient(using: .displayP3) {
                tintGradient.draw(in: rect, angle: 0)
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard
            let overlayPanel,
            let context = NSGraphicsContext.current
        else {
            return
        }

        let drawableBounds = getDrawableBounds()

        let shapePath = switch fullConfiguration.shapeKind {
        case .noShape:
            NSBezierPath(rect: drawableBounds)
        case .full:
            pathForFullShape(
                in: drawableBounds,
                info: fullConfiguration.fullShapeInfo,
                isInset: fullConfiguration.isInset,
                screen: overlayPanel.owningScreen
            )
        case .split:
            pathForSplitShape(
                in: drawableBounds,
                info: fullConfiguration.splitShapeInfo,
                isInset: fullConfiguration.isInset,
                screen: overlayPanel.owningScreen
            )
        }

        var hasBorder = false

        switch fullConfiguration.shapeKind {
        case .noShape:
            if configuration.hasShadow {
                let gradient = NSGradient(
                    colors: [
                        NSColor(white: 0.0, alpha: 0.0),
                        NSColor(white: 0.0, alpha: 0.2),
                    ]
                )
                let shadowBounds = CGRect(
                    x: bounds.minX,
                    y: bounds.minY,
                    width: bounds.width,
                    height: 5
                )
                gradient?.draw(in: shadowBounds, angle: 90)
            }

            drawTint(in: drawableBounds)

            if configuration.hasBorder {
                let borderBounds = CGRect(
                    x: bounds.minX,
                    y: bounds.minY + 5,
                    width: bounds.width,
                    height: configuration.borderWidth
                )
                NSColor(cgColor: configuration.borderColor)?.setFill()
                NSBezierPath(rect: borderBounds).fill()
            }
        case .full, .split:
            if let desktopWallpaper = overlayPanel.desktopWallpaper {
                context.saveGraphicsState()
                defer {
                    context.restoreGraphicsState()
                }

                let invertedClipPath = NSBezierPath(rect: drawableBounds)
                invertedClipPath.append(shapePath.reversed)
                invertedClipPath.setClip()

                context.cgContext.draw(desktopWallpaper, in: drawableBounds)
            }

            if configuration.hasShadow {
                context.saveGraphicsState()
                defer {
                    context.restoreGraphicsState()
                }

                let shadowClipPath = NSBezierPath(rect: bounds)
                shadowClipPath.append(shapePath.reversed)
                shadowClipPath.setClip()

                shapePath.drawShadow(color: .black.withAlphaComponent(0.5), radius: 5)
            }

            if configuration.hasBorder {
                hasBorder = true
            }

            do {
                context.saveGraphicsState()
                defer {
                    context.restoreGraphicsState()
                }

                shapePath.setClip()

                drawTint(in: drawableBounds)
            }

            if
                hasBorder,
                let borderColor = NSColor(cgColor: configuration.borderColor)
            {
                context.saveGraphicsState()
                defer {
                    context.restoreGraphicsState()
                }

                let borderPath = switch fullConfiguration.shapeKind {
                case .noShape:
                    NSBezierPath(rect: drawableBounds)
                case .full:
                    pathForFullShape(
                        in: drawableBounds,
                        info: fullConfiguration.fullShapeInfo,
                        isInset: fullConfiguration.isInset,
                        screen: overlayPanel.owningScreen
                    )
                case .split:
                    pathForSplitShape(
                        in: drawableBounds,
                        info: fullConfiguration.splitShapeInfo,
                        isInset: fullConfiguration.isInset,
                        screen: overlayPanel.owningScreen
                    )
                }

                // HACK: Insetting a path to get an "inside" stroke is surprisingly
                // difficult. We can fake the correct line width by doubling it, as
                // anything outside the shape path will be clipped.
                borderPath.lineWidth = configuration.borderWidth * 2
                borderPath.setClip()

                borderColor.setStroke()
                borderPath.stroke()
            }
        }
    }
}
