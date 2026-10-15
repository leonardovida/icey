//
//  AutoShowManager.swift
//  Ice
//

import Cocoa
import Combine
import OSLog

/// Manager that keeps the hidden section shown while the active display is
/// set to show hidden items automatically (Settings > Displays).
///
/// macOS shares menu bar items between displays, so the hidden section is
/// shown or hidden in the menu bar of every display at once. The section
/// follows the display with the active menu bar, where the user is working,
/// and is checked again when that display changes, when a display is
/// connected or disconnected, and when the setting changes. The idea comes
/// from jordanbaird/Ice#413, which checked only `NSScreen.main`, and only when
/// the screen parameters changed: with two displays side by side, the display
/// that was checked last decided for both.
///
/// While the section is kept shown, automatic rehiding leaves it alone (see
/// ``MenuBarSection/rehide()``). Hiding it by hand still works, and the
/// choice holds until the active display changes.
@MainActor
final class AutoShowManager {
    /// The display the hidden section is kept shown for, if any.
    private(set) var keptShownDisplayID: CGDirectDisplayID?

    /// The display the user hid the section on while it was kept shown.
    private var dismissedDisplayID: CGDirectDisplayID?

    /// The display that had the active menu bar at the last check.
    private var activeDisplayID: CGDirectDisplayID?

    /// The shared app state.
    private weak var appState: AppState?

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// Logger for the manager.
    private let logger = Logger(category: "AutoShowManager")

    /// A Boolean value that indicates whether the hidden section is kept
    /// shown for the active display.
    var keepsHiddenSectionShown: Bool {
        keptShownDisplayID != nil
    }

    /// Performs the initial setup of the manager.
    ///
    /// Call it once the menu bar sections are set up, as it may show the
    /// hidden section straight away.
    func performSetup(with appState: AppState) {
        self.appState = appState
        configureCancellables()
    }

    /// Configures the internal observers for the manager.
    private func configureCancellables() {
        guard let appState else {
            return
        }

        var c = Set<AnyCancellable>()

        // Each display has spaces of its own, so the active space changes
        // when another display becomes active. The app state already
        // follows the active space, including the cases the workspace
        // notification misses. The setting is watched as well, so turning
        // it on or off applies at once. The burst of changes when a display
        // is connected is checked once.
        appState.$activeSpace
            .discardMerge(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification))
            .discardMerge(appState.settings.displays.$configurations)
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                self?.update()
            }
            .store(in: &c)

        // Turning the setting off for the display the section was hidden on
        // ends that choice, so turning it on again shows the section. Other
        // changes, such as to another display, leave the choice alone. The
        // value is read on the next pass of the main queue, once it is set.
        appState.settings.displays.$configurations
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.endDismissalIfSettingTurnedOff()
            }
            .store(in: &c)

        cancellables = c
    }

    /// Forgets the choice to hide the section if the display it was made on
    /// no longer shows hidden items automatically.
    private func endDismissalIfSettingTurnedOff() {
        guard let appState, let dismissedDisplayID else {
            return
        }
        let screen = NSScreen.screens.first { $0.displayID == dismissedDisplayID }
        let showsAutomatically = appState.settings.displays.configuration(for: screen)?.showsHiddenItemsAutomatically ?? false
        if !showsAutomatically {
            self.dismissedDisplayID = nil
        }
    }

    /// Shows or hides the hidden section for the display with the active
    /// menu bar.
    func update() {
        guard
            let appState,
            let hiddenSection = appState.menuBarManager.section(withName: .hidden)
        else {
            return
        }

        // Finding the active display asks the window server, so don't
        // unless a display uses the setting.
        let displays = appState.settings.displays
        guard
            keptShownDisplayID != nil ||
            displays.configurations.values.contains(where: \.showsHiddenItemsAutomatically)
        else {
            activeDisplayID = nil
            dismissedDisplayID = nil
            return
        }

        let screen = NSScreen.screenWithActiveMenuBar ?? NSScreen.main
        let displayID = screen?.displayID

        // The user's choice to hide the section holds only on the display
        // it was made on.
        if displayID != activeDisplayID {
            activeDisplayID = displayID
            dismissedDisplayID = nil
        }

        let showsAutomatically = displays.configuration(for: screen)?.showsHiddenItemsAutomatically ?? false

        if showsAutomatically, let screen, let displayID, displayID != dismissedDisplayID {
            // A section already shown, for example in the Ice Bar or with the
            // application menus hidden, was shown for the old settings. Hide it
            // first, so showing it again puts it in the menu bar and undoes
            // the rest. This runs before the display is recorded, so it doesn't
            // count as hiding it by hand.
            if keptShownDisplayID == nil, !hiddenSection.isHidden {
                hiddenSection.hide()
            }
            // Set first, so showing the section doesn't start rehide checks.
            keptShownDisplayID = displayID
            if hiddenSection.isHidden {
                logger.info("Showing the hidden section for display \(displayID, privacy: .public)")
                hiddenSection.show(on: screen)
            }
        } else if keptShownDisplayID != nil {
            // Cleared first, so hiding the section doesn't count as the user's choice.
            keptShownDisplayID = nil
            logger.info("Hiding the hidden section, as the active display doesn't show hidden items automatically")
            hiddenSection.hide()
        }
    }

    /// Records that the hidden section was hidden.
    ///
    /// While the section is kept shown, only the user hides it, as automatic
    /// rehiding leaves it alone. It then stays hidden until the active
    /// display changes.
    func hiddenSectionWasHidden() {
        guard let keptShownDisplayID else {
            return
        }
        logger.info("The hidden section was hidden by hand, keeping it hidden until the active display changes")
        dismissedDisplayID = keptShownDisplayID
        self.keptShownDisplayID = nil
    }
}
