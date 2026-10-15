//
//  MenuBarManager.swift
//  Ice
//

import Combine
import OSLog
import SwiftUI

/// Manager for the state of the menu bar.
@MainActor
final class MenuBarManager: ObservableObject {
    /// Information for the menu bar's average color.
    @Published private(set) var averageColorInfo: MenuBarAverageColorInfo?

    /// A Boolean value that indicates whether the menu bar is either always hidden
    /// by the system, or automatically hidden and shown by the system based on the
    /// location of the mouse.
    @Published private(set) var isMenuBarHiddenBySystem = false

    /// A Boolean value that indicates whether the "ShowOnHover" feature is allowed.
    @Published var showOnHoverAllowed = true

    /// Reference to the settings window.
    @Published private var settingsWindow: NSWindow?

    /// Logger for the menu bar manager.
    private let logger = Logger(category: "MenuBarManager")

    /// The shared app state.
    private weak var appState: AppState?

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// A Boolean value that indicates whether the application menus are hidden.
    private(set) var isHidingApplicationMenus = false

    /// The pending check of whether shown items reach the application menus.
    private var applicationMenusCheckTask: Task<Void, any Error>?

    /// The panel that contains the Ice Bar interface.
    let iceBarPanel = IceBarPanel()

    /// The panel that contains the menu bar search interface.
    let searchPanel = MenuBarSearchPanel()

    /// The panel that contains a portable version of the menu bar
    /// appearance editor interface
    let appearanceEditorPanel = MenuBarAppearanceEditorPanel()

    /// The managed sections in the menu bar.
    let sections = [
        MenuBarSection(name: .visible),
        MenuBarSection(name: .hidden),
        MenuBarSection(name: .alwaysHidden),
    ]

    /// A Boolean value that indicates whether at least one of the manager's
    /// sections is visible.
    var hasVisibleSection: Bool {
        sections.contains { !$0.isHidden }
    }

    /// A Boolean value that indicates whether the display the sections were
    /// last shown on uses the Ice Bar, as decided by ``MenuBarSection/show()``.
    var shownDisplayUsesIceBar = true

    /// A Boolean value that indicates whether shown sections appear in the
    /// Ice Bar rather than in the menu bar.
    ///
    /// The Ice Bar can be limited to some displays, so this follows the
    /// display a section was last shown on. With the Ice Bar on every display,
    /// it is the "Use Ice Bar" setting.
    var isUsingIceBar: Bool {
        guard let appState else {
            return false
        }
        return appState.settings.general.useIceBar && shownDisplayUsesIceBar
    }

    /// Performs the initial setup of the menu bar manager.
    func performSetup(with appState: AppState) {
        self.appState = appState
        configureCancellables()
        iceBarPanel.performSetup(with: appState)
        searchPanel.performSetup(with: appState)
        appearanceEditorPanel.performSetup(with: appState)
        for section in sections {
            section.performSetup(with: appState)
        }
    }

    /// Configures the internal observers for the manager.
    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        NSApp.publisher(for: \.currentSystemPresentationOptions)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] options in
                guard let self else {
                    return
                }
                let hidden = options.contains(.hideMenuBar) || options.contains(.autoHideMenuBar)
                isMenuBarHiddenBySystem = hidden
            }
            .store(in: &c)

        // Handle the `focusedApp` rehide strategy.
        NSWorkspace.shared.publisher(for: \.frontmostApplication)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                if
                    let self,
                    let appState,
                    case .focusedApp = appState.settings.general.rehideStrategy,
                    let hiddenSection = section(withName: .hidden),
                    let screen = appState.hidEventManager.bestScreen(appState: appState),
                    !appState.hidEventManager.isMouseInsideMenuBar(appState: appState, screen: screen)
                {
                    Task {
                        try await Task.sleep(for: .seconds(0.1))
                        hiddenSection.hide()
                    }
                }
            }
            .store(in: &c)

        appState?.publisherForWindow(.settings)
            .sink { [weak self] window in
                self?.settingsWindow = window
            }
            .store(in: &c)

        $settingsWindow
            .removeNil()
            .flatMap { $0.publisher(for: \.isVisible) }
            .discardMerge(Timer.publish(every: 5, tolerance: 1, on: .main, in: .default).autoconnect())
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.updateAverageColorInfo()
            }
            .store(in: &c)

        // Hide application menus when a section is shown (if applicable).
        Publishers.MergeMany(sections.map { $0.controlItem.$state })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, let appState else {
                    return
                }

                // macOS 27 folds the items that do not fit behind its own overflow button,
                // so shown items never cover the application menus. Activating Ice there only
                // took keyboard focus from the frontmost application (measured).
                if #available(macOS 27.0, *) {
                    return
                }

                // A check still waiting for the items to move is out of date.
                applicationMenusCheckTask?.cancel()
                applicationMenusCheckTask = nil

                let isShowingSection = sections.contains { $0.controlItem.state == .showSection }

                // Give the menus back once no section is shown. This used to sit behind
                // the checks below, so a section hidden while one of them failed (in a
                // fullscreen space, say) left Ice active, with its icon in the Dock,
                // until a section was next shown (jordanbaird/Ice#808). The settings
                // window still keeps Ice active, as it needs a Dock icon of its own.
                if !isShowingSection {
                    if isHidingApplicationMenus {
                        if appState.navigationState.isSettingsPresented {
                            // The settings window keeps Ice active, so only the record
                            // is cleared. Left set, it kept the Dock icon after the user
                            // chose not to have one while Settings is open.
                            isHidingApplicationMenus = false
                            appState.updateSettingsActivationPolicy()
                        } else {
                            showApplicationMenus()
                        }
                    }
                    return
                }

                // Don't continue if:
                //   * The "HideApplicationMenus" setting isn't enabled.
                //   * Using the Ice Bar.
                //   * The menu bar is hidden by the system.
                //   * The active space is fullscreen.
                //   * The settings window is visible.
                guard
                    appState.settings.advanced.hideApplicationMenus,
                    !isUsingIceBar,
                    !isMenuBarHiddenBySystem,
                    !appState.activeSpace.isFullscreen,
                    !appState.navigationState.isSettingsPresented
                else {
                    return
                }

                guard let screen = NSScreen.main else {
                    return
                }

                // Get the application menu frame for the display.
                guard let applicationMenuFrame = screen.getApplicationMenuFrame() else {
                    return
                }

                // Showing a section sets the state of every control item, so
                // this runs several times in a row. Only the last check counts.
                applicationMenusCheckTask = Task {
                    // The items are read through the window server, which
                    // moves them only once the control items have changed
                    // length. Read straight away, they were still where they
                    // were: Option-clicking to show the always-hidden section
                    // after the hidden one found its items still off screen,
                    // and left the application menus in place
                    // (jordanbaird/Ice#144). Wait for the move, and look once
                    // more if the items have not reached the menus by then.
                    for delay in [Duration.milliseconds(100), .milliseconds(250)] {
                        try await Task.sleep(for: delay)
                        guard await self.shownItemsReachApplicationMenus(on: screen, menuFrame: applicationMenuFrame) else {
                            continue
                        }

                        // Reading the items takes a moment, and longer at login on macOS 26,
                        // where each item's owner comes from the item service. A section hidden
                        // in the meantime got no call to give the menus back, as they were not
                        // hidden yet, and Ice then hid them with nothing shown. It stayed active,
                        // with its icon in the Dock, until a section was next shown and hidden
                        // (jordanbaird/Ice#808).
                        guard !Task.isCancelled, self.sections.contains(where: { $0.controlItem.state == .showSection }) else {
                            return
                        }
                        self.hideApplicationMenus()
                        return
                    }
                }
            }
            .store(in: &c)

        cancellables = c
    }

    /// Returns a Boolean value that indicates whether the items of the shown
    /// sections reach the application menus on the given screen.
    private func shownItemsReachApplicationMenus(on screen: NSScreen, menuFrame applicationMenuFrame: CGRect) async -> Bool {
        // Get all items.
        var items = await MenuBarItem.getMenuBarItems(on: screen.displayID, option: .activeSpace)

        // Filter the items down according to the currently enabled/shown sections.
        if
            let alwaysHiddenSection = section(withName: .alwaysHidden),
            alwaysHiddenSection.isEnabled
        {
            if alwaysHiddenSection.controlItem.state == .hideSection {
                if let alwaysHiddenControlItem = items.firstIndex(matching: .alwaysHiddenControlItem).map({ items.remove(at: $0) }) {
                    items.trimPrefix { $0.bounds.maxX <= alwaysHiddenControlItem.bounds.minX }
                }
            }
        } else if
            // Only leave out the hidden items while their section is
            // hidden. Without the always-hidden section, this code runs
            // when the hidden section is shown, so the items left out
            // were the very ones now covering the application menus,
            // and the menus were never hidden (jordanbaird/Ice#434).
            let hiddenSection = section(withName: .hidden),
            hiddenSection.controlItem.state == .hideSection
        {
            if let hiddenControlItem = items.firstIndex(matching: .hiddenControlItem).map({ items.remove(at: $0) }) {
                items.trimPrefix { $0.bounds.maxX <= hiddenControlItem.bounds.minX }
            }
        }

        // Get the leftmost item on the screen.
        guard let leftmostItem = items.min(by: { $0.bounds.minX < $1.bounds.minX }) else {
            return false
        }

        // If the minX of the item is less than or equal to the maxX of the
        // application menu frame, the items reach the menus.
        return leftmostItem.bounds.minX <= applicationMenuFrame.maxX
    }

    /// Updates the ``averageColorInfo`` property with the current average color
    /// of the menu bar.
    func updateAverageColorInfo() {
        guard
            let settingsWindow,
            settingsWindow.isVisible,
            let screen = settingsWindow.screen
        else {
            return
        }

        if #available(macOS 27.0, *) {
            let info = MenuBarAverageColorInfo(color: IceBarColorManager.flatColor27(), source: .menuBarWindow)
            if averageColorInfo != info {
                averageColorInfo = info
            }
            return
        }

        let windows = WindowInfo.createWindows(option: .onScreen)
        let displayID = screen.displayID

        guard
            let menuBarWindow = WindowInfo.menuBarWindow(from: windows, for: displayID),
            let wallpaperWindow = WindowInfo.wallpaperWindow(from: windows, for: displayID)
        else {
            return
        }

        guard
            let image = ScreenCapture.captureWindows(
                with: [menuBarWindow.windowID, wallpaperWindow.windowID],
                screenBounds: withMutableCopy(of: wallpaperWindow.bounds) { $0.size.height = 1 },
                option: .nominalResolution
            ),
            let color = image.averageColor(option: .ignoreAlpha)
        else {
            return
        }

        let info = MenuBarAverageColorInfo(color: color, source: .menuBarWindow)

        if averageColorInfo != info {
            averageColorInfo = info
        }
    }

    /// Returns a Boolean value that indicates whether the given display
    /// has a valid menu bar.
    func hasValidMenuBar(in windows: [WindowInfo], for display: CGDirectDisplayID) -> Bool {
        guard
            let window = WindowInfo.menuBarWindow(from: windows, for: display),
            let element = AXHelpers.element(at: window.bounds.origin)
        else {
            return false
        }
        return AXHelpers.role(for: element) == .menuBar
    }

    /// Shows the secondary context menu.
    func showSecondaryContextMenu(at point: CGPoint) {
        let menu = NSMenu(title: "Icey")

        let editAppearanceItem = NSMenuItem(
            title: String(localized: "Edit Menu Bar Appearance…"),
            action: #selector(showAppearanceEditorPanel),
            keyEquivalent: ""
        )
        editAppearanceItem.target = self
        menu.addItem(editAppearanceItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: String(localized: "Icey Settings…"),
            action: #selector(AppDelegate.openSettingsWindow),
            keyEquivalent: ","
        )
        menu.addItem(settingsItem)

        menu.popUp(positioning: nil, at: point, in: nil)
    }

    /// Hides the application menus.
    func hideApplicationMenus() {
        guard let appState else {
            logger.error("Error hiding application menus: Missing app state")
            return
        }
        logger.info("Hiding application menus")
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let isAllowed = appState.activate(withPolicy: .regular)
        isHidingApplicationMenus = true

        // The frontmost app never yields activation to Icey, and the system
        // can refuse a request that it did not yield for. The Dock icon then
        // appeared, from the activation policy, but the application menus
        // stayed (jordanbaird/Ice#620, #879). The user has just asked for
        // the items, so Icey takes activation instead, unless the user has
        // switched to another app in the meantime.
        Task {
            if isAllowed {
                try await Task.sleep(for: .milliseconds(250))
            }
            guard
                isHidingApplicationMenus,
                !NSApp.isActive,
                NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmostPID
            else {
                return
            }
            logger.info("Activation was refused, activating regardless")
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Shows the application menus.
    func showApplicationMenus() {
        guard let appState else {
            logger.error("Error showing application menus: Missing app state")
            return
        }
        logger.info("Showing application menus")
        appState.deactivate(withPolicy: .accessory)
        isHidingApplicationMenus = false
    }

    /// Toggles the visibility of the application menus.
    func toggleApplicationMenus() {
        if isHidingApplicationMenus {
            showApplicationMenus()
        } else {
            hideApplicationMenus()
        }
    }

    /// Shows the appearance editor panel.
    @objc private func showAppearanceEditorPanel() {
        guard let screen = MenuBarAppearanceEditorPanel.defaultScreen else {
            return
        }
        appearanceEditorPanel.show(on: screen)
    }

    /// Returns the menu bar section with the given name.
    func section(withName name: MenuBarSection.Name) -> MenuBarSection? {
        sections.first { $0.name == name }
    }

    /// Returns the control item for the menu bar section with the given name.
    func controlItem(withName name: MenuBarSection.Name) -> ControlItem? {
        section(withName: name)?.controlItem
    }
}

// MARK: - MenuBarAverageColorInfo

/// Information for the average color of the menu bar.
struct MenuBarAverageColorInfo: Hashable {
    /// Sources used to compute the average color of the menu bar.
    enum Source: Hashable {
        case menuBarWindow
        case desktopWallpaper
    }

    /// The average color of the menu bar
    var color: CGColor

    /// The source used to compute the color.
    var source: Source

    /// The brightness of the menu bar's color.
    var brightness: CGFloat { color.brightness ?? 0 }

    /// A Boolean value that indicates whether the menu bar has a
    /// bright color.
    ///
    /// This value is `true` if ``brightness`` is above `0.67`. At
    /// the time of writing, if this value is `true`, the menu bar
    /// draws its items with a darker appearance.
    var isBright: Bool { brightness > 0.67 }
}
