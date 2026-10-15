//
//  MenuBarSection.swift
//  Ice
//

import SwiftUI

/// A representation of a section in a menu bar.
@MainActor
final class MenuBarSection {
    /// The name of a menu bar section.
    enum Name: CaseIterable {
        case visible
        case hidden
        case alwaysHidden

        /// A localized string to show in the interface.
        var displayString: String {
            switch self {
            case .visible: String(localized: "Visible")
            case .hidden: String(localized: "Hidden")
            case .alwaysHidden: String(localized: "Always-Hidden")
            }
        }

        /// A string to use for logging purposes.
        var logString: String {
            switch self {
            case .visible: "visible section"
            case .hidden: "hidden section"
            case .alwaysHidden: "always-hidden section"
            }
        }
    }

    /// The name of the section.
    let name: Name

    /// The control item that manages the section.
    let controlItem: ControlItem

    /// The shared app state.
    private weak var appState: AppState?

    /// A timer that manages rehiding the section.
    private var rehideTimer: Timer?

    /// An event monitor that handles starting the rehide timer when the mouse
    /// is outside of the menu bar.
    private var rehideMonitor: EventMonitor?

    /// A Boolean value that indicates whether shown sections appear in
    /// the Ice Bar.
    private var useIceBar: Bool {
        menuBarManager?.isUsingIceBar ?? false
    }

    /// A weak reference to the menu bar manager.
    private weak var menuBarManager: MenuBarManager? {
        appState?.menuBarManager
    }

    /// The best screen to show the Ice Bar on.
    /// Uses the screen under the mouse so Ice Bar appears on the correct
    /// display when using multiple monitors (e.g. external monitor).
    private weak var screenForIceBar: NSScreen? {
        guard appState != nil else {
            return nil
        }
        return NSScreen.screenWithMouse ?? NSScreen.main
    }

    /// A Boolean value that indicates whether the section is hidden.
    var isHidden: Bool {
        if useIceBar {
            if controlItem.state == .showSection {
                return false
            }
            switch name {
            case .visible, .hidden:
                return menuBarManager?.iceBarPanel.currentSection != .hidden
            case .alwaysHidden:
                return menuBarManager?.iceBarPanel.currentSection != .alwaysHidden
            }
        }
        switch name {
        case .visible, .hidden:
            if menuBarManager?.iceBarPanel.currentSection == .hidden {
                return false
            }
            return controlItem.state == .hideSection
        case .alwaysHidden:
            if menuBarManager?.iceBarPanel.currentSection == .alwaysHidden {
                return false
            }
            return controlItem.state == .hideSection
        }
    }

    /// A Boolean value that indicates whether the section is enabled.
    var isEnabled: Bool {
        if case .visible = name {
            // The visible section should always be enabled.
            return true
        }
        return controlItem.isAddedToMenuBar
    }

    /// The hotkey to toggle the section.
    var hotkey: Hotkey? {
        guard let hotkeys = appState?.settings.hotkeys else {
            return nil
        }
        return switch name {
        case .visible: nil
        case .hidden: hotkeys.hotkey(withAction: .toggleHiddenSection)
        case .alwaysHidden: hotkeys.hotkey(withAction: .toggleAlwaysHiddenSection)
        }
    }

    /// Creates a section with the given name and control item.
    init(name: Name, controlItem: ControlItem) {
        self.name = name
        self.controlItem = controlItem
    }

    /// Creates a section with the given name.
    convenience init(name: Name) {
        let controlItem = switch name {
        case .visible:
            ControlItem(identifier: .visible)
        case .hidden:
            ControlItem(identifier: .hidden)
        case .alwaysHidden:
            ControlItem(identifier: .alwaysHidden)
        }
        self.init(name: name, controlItem: controlItem)
    }

    /// Performs the initial setup of the section.
    func performSetup(with appState: AppState) {
        self.appState = appState
        controlItem.performSetup(with: appState)
    }

    /// Shows the section.
    func show() {
        guard let menuBarManager, isHidden else {
            return
        }

        guard controlItem.isAddedToMenuBar else {
            // The section is disabled.
            // TODO: Can we use isEnabled for this check?
            return
        }

        // The Ice Bar can be limited to some displays. Decide for the display
        // it would appear on, so a display that does not use it shows the
        // section in the menu bar instead. Hiding follows this decision.
        let screen = screenForIceBar
        if let appState {
            let general = appState.settings.general
            menuBarManager.shownDisplayUsesIceBar = general.iceBarDisplays.includes(screen, widthThreshold: general.iceBarWidthThreshold)
        }

        if useIceBar {
            // Make sure hidden and always-hidden control items are collapsed.
            // Still update the visible control item (Ice icon) state to show
            // its alternate icon.
            for section in menuBarManager.sections {
                switch section.name {
                case .visible:
                    section.controlItem.state = .showSection
                case .hidden, .alwaysHidden:
                    section.controlItem.state = .hideSection
                }
            }

            if let screen {
                Task {
                    switch name {
                    case .visible, .hidden:
                        await menuBarManager.iceBarPanel.show(section: .hidden, on: screen)
                    case .alwaysHidden:
                        await menuBarManager.iceBarPanel.show(section: .alwaysHidden, on: screen)
                    }
                    startRehideChecks()
                }
            }

            updateConcealment27()
            return // We're done.
        }

        // If we made it here, we're not using the Ice Bar.
        // Make sure it's closed.
        menuBarManager.iceBarPanel.close()

        switch name {
        case .visible, .hidden:
            for section in menuBarManager.sections where section.name != .alwaysHidden {
                section.controlItem.state = .showSection
            }
        case .alwaysHidden:
            for section in menuBarManager.sections {
                section.controlItem.state = .showSection
            }
        }

        startRehideChecks()
        updateConcealment27()
    }

    /// Hides the section.
    func hide() {
        guard let menuBarManager, !isHidden else {
            return
        }

        menuBarManager.iceBarPanel.close() // Make sure Ice Bar is always closed.
        menuBarManager.showOnHoverAllowed = true

        switch name {
        case _ where useIceBar, .visible, .hidden:
            for section in menuBarManager.sections {
                section.controlItem.state = .hideSection
            }
        case .alwaysHidden:
            controlItem.state = .hideSection
        }

        stopRehideChecks()
        updateConcealment27()
    }

    /// Toggles the visibility of the section.
    func toggle() {
        if isHidden { show() } else { hide() }
    }

    /// Lets the macOS 27 concealer follow the new state of the sections.
    private func updateConcealment27() {
        if #available(macOS 27.0, *) {
            appState?.concealer27.update()
        }
    }

    /// Starts running checks to determine when to rehide the section.
    private func startRehideChecks() {
        // Clear the reference too: the monitor below only schedules a new timer
        // while it is nil, so an invalidated but retained timer would stop timed
        // rehide from ever re-arming.
        rehideTimer?.invalidate()
        rehideTimer = nil
        rehideMonitor?.stop()

        guard
            let appState,
            appState.settings.general.autoRehide,
            case .timed = appState.settings.general.rehideStrategy
        else {
            return
        }

        // The pointer counts as outside when it is not in the menu bar and not
        // over the Ice Bar, which sits below the menu bar. Counting the Ice Bar
        // as outside closed it while the pointer was on its way to it, or while
        // it was being used (jordanbaird/Ice#914). A menu bar the system hides
        // automatically takes no space from the visible frame, so the event
        // manager's check is asked as well, which covers it (#708).
        let isMouseOutside = { [weak appState] (screen: NSScreen) -> Bool in
            guard NSEvent.mouseLocation.y < screen.visibleFrame.maxY else {
                return false
            }
            guard let appState else {
                return true
            }
            let hidEventManager = appState.hidEventManager
            return !hidEventManager.isMouseInsideMenuBar(appState: appState, screen: screen) &&
                !hidEventManager.isMouseInsideOrAwaitingIceBar(appState: appState)
        }

        // Asked only when the timer fires, never per event.
        let isMenuBarInterfaceOpen = { [weak appState] (screen: NSScreen) -> Bool in
            guard let appState else {
                return false
            }
            return !appState.hidEventManager.menuBarInterfaceWindows(on: screen).isEmpty
        }

        rehideMonitor = EventMonitor.universal(for: .mouseMoved) { [weak self] event in
            guard
                let self,
                let screen = NSScreen.screenWithMouse ?? NSScreen.main
            else {
                return event
            }
            if isMouseOutside(screen) {
                if rehideTimer == nil {
                    rehideTimer = .scheduledTimer(
                        withTimeInterval: appState.settings.general.rehideInterval,
                        repeats: false
                    ) { [weak self] _ in
                        guard
                            let self,
                            let screen = NSScreen.screenWithMouse ?? NSScreen.main
                        else {
                            return
                        }
                        // A menu or popover of an item hangs below the menu
                        // bar, so the pointer is outside it while the menu is
                        // in use. Hiding the items closed the menu under the
                        // pointer (jordanbaird/Ice#452), so wait for it to close.
                        if isMouseOutside(screen), !isMenuBarInterfaceOpen(screen) {
                            Task {
                                await self.hide()
                            }
                        } else {
                            Task {
                                await self.startRehideChecks()
                            }
                        }
                    }
                }
            } else {
                rehideTimer?.invalidate()
                rehideTimer = nil
            }
            return event
        }

        rehideMonitor?.start()
    }

    /// Stops running checks to determine when to rehide the section.
    private func stopRehideChecks() {
        rehideTimer?.invalidate()
        rehideMonitor?.stop()
        rehideTimer = nil
        rehideMonitor = nil
    }
}
