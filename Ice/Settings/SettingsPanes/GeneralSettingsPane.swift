//
//  GeneralSettingsPane.swift
//  Ice
//

import LaunchAtLogin
import SwiftUI

struct GeneralSettingsPane: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var settings: GeneralSettings
    @State private var isImportingCustomIceIcon = false
    @State private var isPresentingError = false
    @State private var presentedError: LocalizedErrorWrapper?
    @State private var isApplyingItemSpacingOffset = false
    @State private var tempItemSpacingOffset: CGFloat = 0

    private var itemSpacingOffsetKey: LocalizedStringKey {
        switch tempItemSpacingOffset {
        case -16: "none"
        case 0: "default"
        case 16: "max"
        default: LocalizedStringKey(tempItemSpacingOffset.formatted())
        }
    }

    private var rehideIntervalKey: LocalizedStringKey {
        let formatted = settings.rehideInterval.formatted()
        if settings.rehideInterval == 1 {
            return "\(formatted) second"
        } else {
            return "\(formatted) seconds"
        }
    }

    var body: some View {
        IceForm {
            IceSection {
                appOptions
            }
            IceSection {
                iceIconOptions
            }
            IceSection {
                iceBarOptions
            }
            IceSection {
                showOptions
            }
            IceSection {
                rehideOptions
            }
            if #unavailable(macOS 27.0) {
                // Items can't be moved on macOS 27. There, an app that isn't
                // in the saved layout is already shown in the visible section.
                IceSection {
                    newItemOptions
                }
            }
            IceSection {
                spacingOptions
            }
        }
    }

    // MARK: App Options

    @ViewBuilder
    private var appOptions: some View {
        LaunchAtLogin.Toggle()
    }

    // MARK: Ice Icon Options

    @ViewBuilder
    private var iceIconOptions: some View {
        showIceIcon
        if settings.showIceIcon {
            iceIconPicker
        }
    }

    @ViewBuilder
    private var showIceIcon: some View {
        Toggle("Show Icey icon", isOn: $settings.showIceIcon)
            .annotation("Click to show hidden menu bar items. Right-click to access Icey's settings.")
    }

    @ViewBuilder
    private var iceIconPicker: some View {
        let labelKey = LocalizedStringKey("Icey icon")

        IceMenu(labelKey) {
            Picker(labelKey, selection: $settings.iceIcon) {
                ForEach(ControlItemImageSet.userSelectableIceIcons) { imageSet in
                    Button {
                        settings.iceIcon = imageSet
                    } label: {
                        iceIconMenuItem(for: imageSet)
                    }
                    .tag(imageSet)
                }
                if let lastCustomIceIcon = settings.lastCustomIceIcon {
                    Button {
                        settings.iceIcon = lastCustomIceIcon
                    } label: {
                        iceIconMenuItem(for: lastCustomIceIcon)
                    }
                    .tag(lastCustomIceIcon)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()

            Divider()

            Button("Choose image…") {
                isImportingCustomIceIcon = true
            }
        } title: {
            iceIconMenuItem(for: settings.iceIcon)
        }
        .annotation("Choose a custom icon to show in the menu bar.")
        .fileImporter(
            isPresented: $isImportingCustomIceIcon,
            allowedContentTypes: [.image]
        ) { result in
            do {
                let url = try result.get()
                if url.startAccessingSecurityScopedResource() {
                    defer { url.stopAccessingSecurityScopedResource() }
                    let data = try Data(contentsOf: url)
                    settings.iceIcon = ControlItemImageSet(name: .custom, image: .data(data))
                }
            } catch {
                presentedError = LocalizedErrorWrapper(error)
                isPresentingError = true
            }
        }
        .alert(isPresented: $isPresentingError, error: presentedError) {
            Button("OK") {
                presentedError = nil
                isPresentingError = false
            }
        }

        if case .custom = settings.iceIcon.name {
            Toggle("Custom icon uses dynamic appearance", isOn: $settings.customIceIconIsTemplate)
                .annotation {
                    Text(
                        """
                        Display the icon as a monochrome image that dynamically adjusts to match \
                        the menu bar's appearance. This setting removes all color from the icon, \
                        but ensures consistent rendering with both light and dark backgrounds.
                        """
                    )
                    .padding(.trailing, 50)
                }
        }
    }

    @ViewBuilder
    private func iceIconMenuItem(for imageSet: ControlItemImageSet) -> some View {
        Label {
            Text(imageSet.name.localized)
        } icon: {
            if let nsImage = imageSet.hidden.nsImage(for: appState) {
                switch imageSet.name {
                case .custom:
                    Image(size: CGSize(width: 18, height: 18)) { context in
                        context.draw(Image(nsImage: nsImage), in: context.clipBoundingRect)
                    }
                default:
                    Image(nsImage: nsImage)
                }
            }
        }
    }

    // MARK: Ice Bar Options

    @ViewBuilder
    private var iceBarOptions: some View {
        useIceBar
        if settings.useIceBar {
            iceBarDisplaysPicker
            if case .narrowerThan = settings.iceBarDisplays {
                iceBarWidthThreshold
            }
            iceBarLocationPicker
            animateIceBar
        }
    }

    @ViewBuilder
    private var useIceBar: some View {
        Toggle("Use Ice Bar", isOn: $settings.useIceBar)
            .annotation("Show hidden menu bar items in a separate bar below the menu bar.")
    }

    @ViewBuilder
    private var iceBarDisplaysPicker: some View {
        IcePicker("Use on", selection: $settings.iceBarDisplays) {
            ForEach(IceBarDisplays.allCases) { displays in
                Text(displays.localized).tag(displays)
            }
        }
        .annotation {
            switch settings.iceBarDisplays {
            case .all:
                Text("The Ice Bar is used on every display.")
            case .withNotch:
                Text("Displays without a notch show hidden menu bar items in the menu bar.")
            case .builtIn:
                Text("Other displays show hidden menu bar items in the menu bar.")
            case .narrowerThan:
                Text("Wider displays show hidden menu bar items in the menu bar.")
            }
        }
    }

    @ViewBuilder
    private var iceBarWidthThreshold: some View {
        let range = IceBarDisplays.widthThresholdRange
        // Typed values outside the range are clamped, as a display
        // narrower than 800 points or wider than 8000 points doesn't exist.
        let threshold = Binding {
            settings.iceBarWidthThreshold
        } set: { newValue in
            settings.iceBarWidthThreshold = newValue.isFinite ? newValue.clamped(to: range) : IceBarDisplays.defaultWidthThreshold
        }

        LabeledContent {
            HStack(spacing: 6) {
                TextField(
                    "Width threshold",
                    value: threshold,
                    format: .number.precision(.fractionLength(0)).grouping(.never)
                )
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 60)
                Stepper("Width threshold", value: threshold, in: range, step: 100)
                    .labelsHidden()
                Text("points")
            }
        } label: {
            Text("Width threshold")
        }
        .annotation("The Ice Bar is used on displays narrower than this. The Displays pane lists the width of each display.")
    }

    @ViewBuilder
    private var iceBarLocationPicker: some View {
        IcePicker("Location", selection: $settings.iceBarLocation) {
            ForEach(IceBarLocation.allCases) { location in
                Text(location.localized).tag(location)
            }
        }
        .annotation {
            switch settings.iceBarLocation {
            case .dynamic:
                Text("The Ice Bar's location changes based on context.")
            case .mousePointer:
                Text("The Ice Bar is centered below the mouse pointer.")
            case .iceIcon:
                Text("The Ice Bar is centered below the Icey icon.")
            }
        }
    }

    @ViewBuilder
    private var animateIceBar: some View {
        Toggle("Fade in and out", isOn: $settings.animateIceBar)
            .annotation("Fade the Ice Bar in when it opens and out when it closes.")
    }

    // MARK: Show Options

    @ViewBuilder
    private var showOptions: some View {
        Toggle("Show on click", isOn: $settings.showOnClick)
            .annotation("Click inside an empty area of the menu bar to show hidden menu bar items.")
        Toggle("Show on hover", isOn: $settings.showOnHover)
            .annotation("Hover over an empty area of the menu bar to show hidden menu bar items.")
        Toggle("Show on scroll", isOn: $settings.showOnScroll)
            .annotation("Scroll or swipe in the menu bar to show hidden menu bar items.")
    }

    // MARK: Rehide Options

    @ViewBuilder
    private var rehideOptions: some View {
        autoRehide
        if settings.autoRehide {
            rehideStrategyPicker
        }
    }

    @ViewBuilder
    private var autoRehide: some View {
        Toggle("Automatically rehide", isOn: $settings.autoRehide)
    }

    @ViewBuilder
    private var rehideStrategyPicker: some View {
        VStack {
            IcePicker("Strategy", selection: $settings.rehideStrategy) {
                ForEach(RehideStrategy.allCases) { strategy in
                    Text(strategy.localized).tag(strategy)
                }
            }
            .annotation {
                switch settings.rehideStrategy {
                case .smart:
                    Text("Menu bar items are rehidden using a smart algorithm.")
                case .timed:
                    Text("Menu bar items are rehidden after a fixed amount of time.")
                case .focusedApp:
                    Text("Menu bar items are rehidden when the focused app changes.")
                }
            }

            if case .timed = settings.rehideStrategy {
                IceSlider(
                    rehideIntervalKey,
                    value: $settings.rehideInterval,
                    in: 0...30,
                    step: 1
                )
            }
        }
    }

    // MARK: New Item Options

    @ViewBuilder
    private var newItemOptions: some View {
        IcePicker("New items appear in", selection: $settings.newItemPlacement) {
            ForEach(NewItemPlacement.allCases) { placement in
                Text(placement.localized).tag(placement)
            }
        }
        .annotation {
            switch settings.newItemPlacement {
            case .automatic:
                Text("macOS adds new menu bar items at the far left of the menu bar, in the leftmost section.")
            case .alwaysHidden where !appState.settings.advanced.enableAlwaysHiddenSection:
                Text("The always-hidden section is turned off, so Icey moves new menu bar items to the hidden section.")
            case .visible, .hidden, .alwaysHidden:
                Text("Icey moves each menu bar item it hasn't seen before to this section once. Items you move afterwards stay where you put them.")
            }
        }
    }

    // MARK: Spacing Options

    @ViewBuilder
    private var spacingOptions: some View {
        LabeledContent {
            IceSlider(
                itemSpacingOffsetKey,
                value: $tempItemSpacingOffset,
                in: -16...16,
                step: 2
            )
            .disabled(isApplyingItemSpacingOffset)
        } label: {
            LabeledContent {
                Button("Apply") {
                    applyTempItemSpacingOffset()
                }
                .help("Apply the current spacing")
                .disabled(isApplyingItemSpacingOffset || tempItemSpacingOffset == settings.itemSpacingOffset)

                if isApplyingItemSpacingOffset {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.5)
                        .frame(width: 15, height: 15)
                } else {
                    Button {
                        tempItemSpacingOffset = 0
                        applyTempItemSpacingOffset()
                    } label: {
                        Image(systemName: "arrow.counterclockwise.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Reset to the default spacing")
                    .disabled(isApplyingItemSpacingOffset || settings.itemSpacingOffset == 0)
                }
            } label: {
                HStack {
                    Text("Menu bar item spacing")
                    BetaBadge()
                }
            }
        }
        .annotation(
            "Applying this setting asks all apps with menu bar items to quit and reopen. Apps that don't quit, such as ones asking to save your work, are left open and listed.",
            spacing: 2
        )
        .annotation(spacing: 10) {
            CalloutBox(
                "Note: You may need to log out and back in for this setting to apply properly.",
                systemImage: "exclamationmark.circle"
            )
        }
        .onAppear {
            tempItemSpacingOffset = settings.itemSpacingOffset
        }
        .onChange(of: settings.itemSpacingOffset) { _, offset in
            // A settings window restored at launch appears before the saved
            // value is loaded, so it showed the default (jordanbaird/Ice#392).
            tempItemSpacingOffset = offset
        }
    }

    private func applyTempItemSpacingOffset() {
        isApplyingItemSpacingOffset = true
        settings.itemSpacingOffset = tempItemSpacingOffset
        Task {
            do {
                try await appState.spacingManager.applyOffset()
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
            isApplyingItemSpacingOffset = false
        }
    }
}
