//
//  DisplaysSettingsPane.swift
//  Ice
//

import SwiftUI

struct DisplaysSettingsPane: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var settings: DisplaySettings

    var body: some View {
        IceForm {
            ForEach(settings.connectedDisplays) { display in
                IceSection {
                    displayHeader(for: display)
                } content: {
                    iceBarPicker(for: display)
                    showHiddenItemsToggle(for: display)
                }
            }
            CalloutBox(
                "macOS shows the same menu bar items on every display, so hidden items shown automatically appear in the menu bar of each display.",
                systemImage: "info.circle"
            )
            let disconnected = settings.disconnectedConfigurations
            if !disconnected.isEmpty {
                IceSection("Not Connected") {
                    ForEach(disconnected, id: \.id) { entry in
                        disconnectedDisplayRow(id: entry.id, configuration: entry.configuration)
                    }
                }
                .annotation("Icey keeps the settings of these displays for when they are connected again.")
            }
        }
    }

    // MARK: Header

    @ViewBuilder
    private func displayHeader(for display: DisplayInfo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(display.name)
                    .font(.headline)
                Text(details(for: display))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The size of the given display, and whether it is built in or has a notch.
    private func details(for display: DisplayInfo) -> String {
        var details = [String(localized: "\(display.width) × \(display.height) points")]
        if display.isBuiltIn {
            details.append(String(localized: "Built-in display"))
        }
        if display.hasNotch {
            details.append(String(localized: "Notch"))
        }
        return details.joined(separator: " · ")
    }

    // MARK: Ice Bar

    @ViewBuilder
    private func iceBarPicker(for display: DisplayInfo) -> some View {
        let configuration = settings.configuration(for: display)
        let selection = Binding {
            settings.configuration(for: display).iceBar
        } set: { mode in
            settings.updateConfiguration(for: display) { $0.iceBar = mode }
        }

        IcePicker("Use Ice Bar", selection: selection) {
            ForEach(DisplayIceBarMode.allCases) { mode in
                Text(mode.localized).tag(mode)
            }
        }
        .disabled(configuration.showsHiddenItemsAutomatically)
        .annotation {
            if configuration.showsHiddenItemsAutomatically {
                Text("This display shows hidden items automatically, so it doesn't use the Ice Bar.")
            } else {
                switch configuration.iceBar {
                case .followGeneral:
                    if generalSettingUsesIceBar(on: display) {
                        Text("The General setting uses the Ice Bar on this display.")
                    } else {
                        Text("The General setting shows hidden menu bar items in the menu bar on this display.")
                    }
                case .on:
                    Text("The Ice Bar is used on this display.")
                case .off:
                    Text("This display shows hidden menu bar items in the menu bar.")
                }
            }
        }
    }

    /// Returns a Boolean value that indicates whether the General settings
    /// use the Ice Bar on the given display.
    private func generalSettingUsesIceBar(on display: DisplayInfo) -> Bool {
        let screen = NSScreen.screens.first { $0.displayID == display.displayID }
        return appState.settings.general.usesIceBar(on: screen)
    }

    // MARK: Show Hidden Items

    @ViewBuilder
    private func showHiddenItemsToggle(for display: DisplayInfo) -> some View {
        let isOn = Binding {
            settings.configuration(for: display).showsHiddenItemsAutomatically
        } set: { isOn in
            settings.updateConfiguration(for: display) { $0.showsHiddenItemsAutomatically = isOn }
        }

        Toggle("Show hidden items automatically", isOn: isOn)
            .annotation("Show hidden menu bar items while this display has the active menu bar, and keep them shown until you hide them.")
    }

    // MARK: Disconnected Displays

    @ViewBuilder
    private func disconnectedDisplayRow(id: String, configuration: DisplayConfiguration) -> some View {
        LabeledContent {
            Button("Forget") {
                settings.forgetConfiguration(withID: id)
            }
        } label: {
            if configuration.name.isEmpty {
                Text("Unknown display")
            } else {
                Text(configuration.name)
            }
        }
    }
}
