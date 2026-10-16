//
//  Updates.swift
//  Ice
//

import Sparkle
import SwiftUI

/// Manager for app updates.
@MainActor
final class UpdatesManager: NSObject, ObservableObject {
    /// A Boolean value that indicates whether the user can check for updates.
    @Published var canCheckForUpdates = false

    /// The date of the last update check.
    @Published var lastUpdateCheckDate: Date?

    /// The shared app state.
    private(set) weak var appState: AppState?

    /// The underlying updater controller.
    ///
    /// The updater is started in ``performSetup(with:)``, once the rest of
    /// the app is set up, rather than whenever this property is first read.
    private(set) lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: self
    )

    /// The underlying updater.
    var updater: SPUUpdater {
        updaterController.updater
    }

    /// A Boolean value that indicates whether to automatically check for updates.
    var automaticallyChecksForUpdates: Bool {
        get {
            updater.automaticallyChecksForUpdates
        }
        set {
            objectWillChange.send()
            updater.automaticallyChecksForUpdates = newValue
        }
    }

    /// A Boolean value that indicates whether to automatically download updates.
    var automaticallyDownloadsUpdates: Bool {
        get {
            updater.automaticallyDownloadsUpdates
        }
        set {
            objectWillChange.send()
            updater.automaticallyDownloadsUpdates = newValue
        }
    }

    /// Performs the initial setup of the manager.
    func performSetup(with appState: AppState) {
        self.appState = appState
        updaterController.startUpdater()
        configureCancellables()
    }

    /// Configures the internal observers for the manager.
    private func configureCancellables() {
        // Sparkle can report a value again without a change. Assigning it would
        // invalidate every view that observes the app state.
        updater.publisher(for: \.canCheckForUpdates)
            .removeDuplicates()
            .assign(to: &$canCheckForUpdates)
        updater.publisher(for: \.lastUpdateCheckDate)
            .removeDuplicates()
            .assign(to: &$lastUpdateCheckDate)
    }

    /// Checks for app updates.
    @objc func checkForUpdates() {
        #if DEBUG
        // Checking for updates hangs in debug mode.
        let alert = NSAlert()
        alert.messageText = String(localized: "Checking for updates is not supported in debug mode.")
        alert.runModal()
        #else
        guard let appState else {
            return
        }
        // Activate the app in case an alert needs to be displayed, with the
        // Dock icon only if the user wants one while Settings is open.
        appState.activateAndOpenSettings()
        updater.checkForUpdates()
        #endif
    }
}

// MARK: UpdatesManager: SPUUpdaterDelegate
extension UpdatesManager: @preconcurrency SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, willScheduleUpdateCheckAfterDelay delay: TimeInterval) {
        guard let appState else {
            return
        }
        appState.userNotificationManager.requestAuthorization()
    }

    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool {
        // Sparkle only asks this while the user has not answered the prompt yet.
        // Keep its default of asking from the second launch onward.
        guard UserDefaults.standard.bool(forKey: "SUHasLaunchedBefore") else {
            return false
        }
        // Sparkle shows the prompt right after this returns. Ice is an agent app,
        // so without this the prompt can open behind other windows without focus,
        // never get an answer, and come back on every launch.
        appState?.activate(withPolicy: .regular)
        return true
    }
}

// MARK: UpdatesManager: SPUStandardUserDriverDelegate
extension UpdatesManager: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        if NSApp.isActive {
            return immediateFocus
        } else {
            return false
        }
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard let appState else {
            return
        }
        if handleShowingUpdate {
            // Bring the alert Sparkle is about to show to the front, so it
            // can receive input, with the Dock icon only if the user wants
            // one while Icey's windows are open.
            appState.activate(withPolicy: appState.settingsActivationPolicy)
        } else if !state.userInitiated {
            appState.userNotificationManager.addRequest(
                with: .updateCheck,
                title: String(localized: "A new update is available"),
                body: String(localized: "Version \(update.displayVersionString) is now available")
            )
        }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        guard let appState else {
            return
        }
        appState.userNotificationManager.removeDeliveredNotifications(with: [.updateCheck])
    }
}
