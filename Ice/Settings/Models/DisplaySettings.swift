//
//  DisplaySettings.swift
//  Ice
//

import Combine
import OSLog
import SwiftUI

// MARK: - DisplaySettings

/// Model for the app's Displays settings: settings for each display, which
/// take precedence over the General settings on that display
/// (jordanbaird/Ice#612, #413).
///
/// The settings are stored by an identifier that stays the same when a
/// display is disconnected and connected again, or the Mac restarts (see
/// ``identifier(for:)``). The settings of a disconnected display are kept,
/// so they apply again when it comes back.
@MainActor
final class DisplaySettings: ObservableObject {
    /// The settings of each display, by display identifier.
    ///
    /// Displays whose settings all have their default values are left out,
    /// so the dictionary only grows with displays the user configured.
    @Published private(set) var configurations = [String: DisplayConfiguration]()

    /// The connected displays, with the built-in display first.
    ///
    /// Updated when the screen parameters change, so looking up a screen's
    /// identifier doesn't ask the window server each time.
    @Published private(set) var connectedDisplays = [DisplayInfo]()

    /// Encoder for properties.
    private let encoder = JSONEncoder()

    /// Decoder for properties.
    private let decoder = JSONDecoder()

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// The displays that have settings but are not connected, by name.
    var disconnectedConfigurations: [(id: String, configuration: DisplayConfiguration)] {
        let connectedIDs = Set(connectedDisplays.map(\.id))
        return configurations
            .filter { !connectedIDs.contains($0.key) }
            .map { (id: $0.key, configuration: $0.value) }
            .sorted { $0.configuration.name.localizedStandardCompare($1.configuration.name) == .orderedAscending }
    }

    /// Performs the initial setup of the model.
    func performSetup(with appState: AppState) {
        loadInitialState()
        configureCancellables()
        updateConnectedDisplays()
    }

    /// Loads the model's initial state.
    private func loadInitialState() {
        guard let data = Defaults.data(forKey: .displayConfigurations) else {
            return
        }
        do {
            configurations = try decoder.decode([String: DisplayConfiguration].self, from: data)
                .filter { !$0.value.isDefault }
        } catch {
            Logger.serialization.error("Error decoding display configurations: \(error, privacy: .public)")
        }
    }

    /// Configures the internal observers for the model.
    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateConnectedDisplays()
            }
            .store(in: &c)

        // Skip the loaded value, so nothing is written for a user
        // who never changes these settings.
        $configurations
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] configurations in
                guard let self else {
                    return
                }
                do {
                    let data = try encoder.encode(configurations)
                    Defaults.set(data, forKey: .displayConfigurations)
                } catch {
                    Logger.serialization.error("Error encoding display configurations: \(error, privacy: .public)")
                }
            }
            .store(in: &c)

        cancellables = c
    }

    /// Updates the list of connected displays.
    private func updateConnectedDisplays() {
        let displays = NSScreen.screens
            .map(DisplayInfo.init)
            .sorted { lhs, rhs in
                if lhs.isBuiltIn != rhs.isBuiltIn {
                    return lhs.isBuiltIn
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        if displays != connectedDisplays {
            connectedDisplays = displays
        }

        // Keep the name each configured display was last seen with, to
        // list it by that name while it is not connected.
        for display in displays {
            if let configuration = configurations[display.id], configuration.name != display.name {
                configurations[display.id]?.name = display.name
            }
        }
    }

    /// Returns the settings of the given screen, or `nil` if it has none.
    func configuration(for screen: NSScreen?) -> DisplayConfiguration? {
        guard let screen, !configurations.isEmpty else {
            return nil
        }
        let displayID = screen.displayID
        let identifier = connectedDisplays.first { $0.displayID == displayID }?.id ?? Self.identifier(for: screen)
        return configurations[identifier]
    }

    /// Returns the settings of the given display, with default values if it
    /// has none.
    func configuration(for display: DisplayInfo) -> DisplayConfiguration {
        configurations[display.id] ?? DisplayConfiguration()
    }

    /// Changes the settings of the given display.
    func updateConfiguration(for display: DisplayInfo, _ body: (inout DisplayConfiguration) -> Void) {
        var configuration = configuration(for: display)
        body(&configuration)
        configuration.name = display.name
        configurations[display.id] = configuration.isDefault ? nil : configuration
    }

    /// Removes the settings of the display with the given identifier.
    func forgetConfiguration(withID id: String) {
        configurations[id] = nil
    }

    /// Returns the identifier that the settings of the given screen are
    /// stored by.
    ///
    /// The identifier is the display's UUID, which stays the same across
    /// reconnections and restarts, unlike the display ID. A display without
    /// a UUID is identified by its name.
    static func identifier(for screen: NSScreen) -> String {
        if
            let uuid = CGDisplayCreateUUIDFromDisplayID(screen.displayID)?.takeRetainedValue(),
            let string = CFUUIDCreateString(nil, uuid) as String?
        {
            return string
        }
        return "name:\(screen.localizedName)"
    }
}

// MARK: - DisplayConfiguration

/// The settings of one display.
struct DisplayConfiguration: Codable, Hashable {
    /// Whether the display uses the Ice Bar.
    var iceBar = DisplayIceBarMode.followGeneral

    /// A Boolean value that indicates whether the hidden section is shown
    /// automatically while the display has the active menu bar.
    var showsHiddenItemsAutomatically = false

    /// The name the display had when it was last connected.
    var name = ""

    /// A Boolean value that indicates whether every setting has its
    /// default value, in which case the configuration isn't kept.
    var isDefault: Bool {
        iceBar == .followGeneral && !showsHiddenItemsAutomatically
    }

    private enum CodingKeys: String, CodingKey {
        case iceBar
        case showsHiddenItemsAutomatically
        case name
    }

    init() { }

    /// Decodes a configuration. Missing or unknown values get their
    /// defaults, so a configuration saved by another version of Icey
    /// still loads.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if
            let rawValue = try? container.decodeIfPresent(Int.self, forKey: .iceBar),
            let mode = DisplayIceBarMode(rawValue: rawValue)
        {
            iceBar = mode
        }
        if let value = try? container.decodeIfPresent(Bool.self, forKey: .showsHiddenItemsAutomatically) {
            showsHiddenItemsAutomatically = value
        }
        if let value = try? container.decodeIfPresent(String.self, forKey: .name) {
            name = value
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(iceBar.rawValue, forKey: .iceBar)
        try container.encode(showsHiddenItemsAutomatically, forKey: .showsHiddenItemsAutomatically)
        try container.encode(name, forKey: .name)
    }
}

// MARK: - DisplayIceBarMode

/// Whether a display uses the Ice Bar.
enum DisplayIceBarMode: Int, CaseIterable, Identifiable {
    /// The display follows the "Use Ice Bar" and "Use on" settings in
    /// the General settings.
    case followGeneral = 0

    /// The display uses the Ice Bar, even with "Use Ice Bar" turned off.
    case on = 1

    /// The display shows hidden items in the menu bar.
    case off = 2

    var id: Int { rawValue }

    /// Localized string key representation.
    var localized: LocalizedStringKey {
        switch self {
        case .followGeneral: "Follow General setting"
        case .on: "On"
        case .off: "Off"
        }
    }
}

// MARK: - DisplayInfo

/// A connected display.
struct DisplayInfo: Identifiable, Hashable {
    /// The identifier the display's settings are stored by.
    let id: String

    /// The display's current display ID.
    let displayID: CGDirectDisplayID

    /// The display's name.
    let name: String

    /// The display's width, in points.
    let width: Int

    /// The display's height, in points.
    let height: Int

    /// A Boolean value that indicates whether the display is the Mac's
    /// built-in display.
    let isBuiltIn: Bool

    /// A Boolean value that indicates whether the display has a notch.
    let hasNotch: Bool

    /// Creates the information for the given screen.
    @MainActor
    init(screen: NSScreen) {
        self.id = DisplaySettings.identifier(for: screen)
        self.displayID = screen.displayID
        self.name = screen.localizedName
        self.width = Int(exactly: screen.frame.width.rounded()) ?? 0
        self.height = Int(exactly: screen.frame.height.rounded()) ?? 0
        self.isBuiltIn = screen.isBuiltIn
        self.hasNotch = screen.hasNotch
    }
}
