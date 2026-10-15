//
//  AppSettings.swift
//  Ice
//

import Combine
import SwiftUI

/// Top-level model for the app's settings.
@MainActor
final class AppSettings: ObservableObject {
    /// The model for the app's Advanced settings.
    let advanced = AdvancedSettings()

    /// The model for the app's Displays settings.
    let displays = DisplaySettings()

    /// The model for the app's General settings.
    let general = GeneralSettings()

    /// The model for the app's Hotkeys settings.
    let hotkeys = HotkeysSettings()

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// Performs the initial setup of the settings model.
    func performSetup(with appState: AppState) {
        advanced.performSetup(with: appState)
        displays.performSetup(with: appState)
        general.performSetup(with: appState)
        hotkeys.performSetup(with: appState)
        configureCancellables()
    }

    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        advanced.objectWillChange
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
            .store(in: &c)
        displays.objectWillChange
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
            .store(in: &c)
        general.objectWillChange
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
            .store(in: &c)
        hotkeys.objectWillChange
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
            .store(in: &c)

        cancellables = c
    }

    /// Returns a Boolean value that indicates whether hidden items shown on
    /// the given screen go in the Ice Bar rather than in the menu bar.
    ///
    /// A display's own settings take precedence over the General settings.
    /// One that shows hidden items automatically keeps them in the menu bar.
    func usesIceBar(on screen: NSScreen?) -> Bool {
        if let configuration = displays.configuration(for: screen) {
            if configuration.showsHiddenItemsAutomatically {
                return false
            }
            switch configuration.iceBar {
            case .followGeneral:
                break
            case .on:
                return true
            case .off:
                return false
            }
        }
        return general.usesIceBar(on: screen)
    }
}
