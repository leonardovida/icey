//
//  MenuBarAppearanceManager.swift
//  Ice
//

import Cocoa
import Combine
import OSLog

/// A manager for the appearance of the menu bar.
@MainActor
final class MenuBarAppearanceManager: ObservableObject {
    /// The current menu bar appearance configuration.
    @Published var configuration: MenuBarAppearanceConfigurationV2 = .defaultConfiguration

    /// The currently previewed partial configuration.
    @Published var previewConfiguration: MenuBarAppearancePartialConfiguration?

    /// The shared app state.
    private weak var appState: AppState?

    /// Encoder for UserDefaults values.
    private let encoder = JSONEncoder()

    /// Decoder for UserDefaults values.
    private let decoder = JSONDecoder()

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// The currently managed menu bar overlay panels.
    private(set) var overlayPanels = Set<MenuBarOverlayPanel>()

    /// The amount to inset the menu bar if called for by the configuration,
    /// on a menu bar tall enough to take it.
    private let preferredMenuBarInsetAmount: CGFloat = if #available(macOS 26.0, *) { 3.5 } else { 5 }

    /// Returns the amount to inset a menu bar of the given height if called
    /// for by the configuration.
    ///
    /// The inset is a fixed amount, but a notched display set to a lower
    /// resolution has a shorter menu bar. At 1168x755 the inset shape and
    /// the Ice Bar, which are both inset by this amount at the top and
    /// bottom, became shorter than the menu bar items and cut them off
    /// (jordanbaird/Ice#260). Keep the inset shape at least as tall as a
    /// status item.
    func menuBarInsetAmount(forMenuBarHeight menuBarHeight: CGFloat) -> CGFloat {
        let availableInset = (menuBarHeight - NSStatusBar.system.thickness) / 2
        return max(0, min(preferredMenuBarInsetAmount, availableInset))
    }

    /// Performs initial setup of the manager.
    func performSetup(with appState: AppState) {
        self.appState = appState
        loadInitialState()
        configureCancellables()
    }

    /// Loads the initial values for the configuration.
    private func loadInitialState() {
        do {
            if let data = Defaults.data(forKey: .menuBarAppearanceConfigurationV2) {
                configuration = try decoder.decode(MenuBarAppearanceConfigurationV2.self, from: data)
            }
        } catch {
            Logger.serialization.error("Error decoding menu bar appearance configuration: \(error)")
        }
    }

    /// Configures the internal observers for the manager.
    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: 0.1, scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else {
                    return
                }
                // Rebuild the panels for the new set of displays. This used to
                // order the old panels out without closing them, which left them
                // alive with their timers and observers running, and compared
                // the displays against the set it had just emptied, so it rebuilt
                // whenever any display was attached. `configureOverlayPanels(with:)`
                // closes the old panels.
                configureOverlayPanels(with: configuration)
            }
            .store(in: &c)

        $configuration
            .encode(encoder: encoder)
            .receive(on: DispatchQueue.main)
            .sink { completion in
                if case .failure(let error) = completion {
                    Logger.serialization.error("Error encoding menu bar appearance configuration: \(error)")
                }
            } receiveValue: { data in
                Defaults.set(data, forKey: .menuBarAppearanceConfigurationV2)
            }
            .store(in: &c)

        $configuration
            .throttle(for: 0.1, scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] configuration in
                guard let self else {
                    return
                }
                // The overlay panels may not have been configured yet. Since some of the
                // properties on the manager might call for them, try to configure now.
                // Also remove them once they are no longer needed, as each panel runs
                // its own timers, event monitors, and Accessibility polling.
                if overlayPanels.isEmpty || !mayNeedOverlayPanels(for: configuration) {
                    configureOverlayPanels(with: configuration)
                }
            }
            .store(in: &c)

        cancellables = c
    }

    /// Returns a Boolean value that indicates whether a set of overlay panels
    /// is needed for the given configuration.
    private func needsOverlayPanels(for configuration: MenuBarAppearanceConfigurationV2) -> Bool {
        let current = configuration.current
        if current.hasShadow {
            return true
        }
        if current.hasBorder {
            return true
        }
        if configuration.shapeKind != .noShape {
            return true
        }
        if current.tintKind != .noTint {
            return true
        }
        return false
    }

    /// Returns a Boolean value that indicates whether a set of overlay panels
    /// may be needed for the given configuration, in either light or dark mode.
    func mayNeedOverlayPanels(for configuration: MenuBarAppearanceConfigurationV2) -> Bool {
        if configuration.shapeKind != .noShape {
            return true
        }
        let partials = if configuration.isDynamic {
            [configuration.lightModeConfiguration, configuration.darkModeConfiguration]
        } else {
            [configuration.staticConfiguration]
        }
        return partials.contains { $0.hasShadow || $0.hasBorder || $0.tintKind != .noTint }
    }

    /// Configures the manager's overlay panels, if required by the given configuration.
    private func configureOverlayPanels(with configuration: MenuBarAppearanceConfigurationV2) {
        guard
            let appState,
            needsOverlayPanels(for: configuration)
        else {
            while let panel = overlayPanels.popFirst() {
                panel.close()
            }
            return
        }

        // Close the panels being replaced before building their successors.
        //
        // A visible NSWindow is retained by AppKit, so dropping the last Swift
        // reference to it does not close it. Reassigning `overlayPanels` therefore
        // left the previous set alive and on screen, each panel still running its
        // own update loops. This function runs on every screen-parameter change,
        // so attaching and detaching a display accumulated a full set of live
        // panels per display each time, all competing to own the menu bar's
        // appearance. The not-needed path above already closes them; this one did
        // not.
        while let panel = overlayPanels.popFirst() {
            panel.close()
        }

        var overlayPanels = Set<MenuBarOverlayPanel>()
        for screen in NSScreen.screens {
            let panel = MenuBarOverlayPanel(appState: appState, owningScreen: screen)
            overlayPanels.insert(panel)
            panel.needsShow = true
        }

        self.overlayPanels = overlayPanels
    }
}
