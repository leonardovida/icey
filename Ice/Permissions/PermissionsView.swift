//
//  PermissionsView.swift
//  Ice
//

import SwiftUI

struct PermissionsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var manager: AppPermissions

    /// The titles of the permissions whose entries could not be reset.
    @State private var failedResets = Set<String>()

    private var continueButtonText: LocalizedStringKey {
        if case .hasRequired = manager.permissionsState {
            "Continue in Limited Mode"
        } else {
            "Continue"
        }
    }

    private var continueButtonForegroundStyle: some ShapeStyle {
        switch manager.permissionsState {
        case .missing:
            AnyShapeStyle(.secondary)
        case .hasAll:
            AnyShapeStyle(.primary)
        case .hasRequired:
            AnyShapeStyle(Color("LimitedModeButtonColor"))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView
                .padding(.vertical)

            permissionsStack

            footerView
                .padding(.vertical)
        }
        .padding(.horizontal)
        .frame(width: 550)
        .fixedSize()
    }

    @ViewBuilder
    private var headerView: some View {
        Label {
            Text("Permissions")
                .font(.largeTitle.weight(.semibold))
        } icon: {
            if let nsImage = NSImage(named: NSImage.applicationIconName) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private var explanationBox: some View {
        IceSection {
            VStack(spacing: 6) {
                Text("Icey needs your permission to manage the menu bar.")
                    .font(.title3)
                Label("No personal information is collected or stored.", systemImage: "lock.shield")
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var permissionsStack: some View {
        VStack {
            explanationBox
            ForEach(manager.allPermissions) { permission in
                permissionBox(permission)
            }
        }
    }

    @ViewBuilder
    private var footerView: some View {
        HStack {
            quitButton
                .keyboardShortcut(.cancelAction)
            continueButton
                .keyboardShortcut(.defaultAction)
        }
        .controlSize(.large)
    }

    @ViewBuilder
    private var quitButton: some View {
        Button {
            NSApp.terminate(nil)
        } label: {
            Text("Quit")
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var continueButton: some View {
        Button {
            appState.dismissWindow(.permissions)

            guard manager.permissionsState != .missing else {
                appState.performSetup(hasPermissions: false)
                return
            }

            appState.performSetup(hasPermissions: true)

            Task {
                appState.activateAndOpenSettings()
            }
        } label: {
            Text(continueButtonText)
                .frame(maxWidth: .infinity)
                .foregroundStyle(continueButtonForegroundStyle)
        }
        .disabled(manager.permissionsState == .missing)
    }

    @ViewBuilder
    private func permissionBox(_ permission: Permission) -> some View {
        IceSection {
            VStack(spacing: 12) {
                Text(permission.title)
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Icey needs this to:")
                        .font(.headline)

                    ForEach(permission.details, id: \.self) { detail in
                        Label(detail, systemImage: "checkmark")
                            .labelStyle(PermissionDetailLabelStyle())
                    }
                }

                if permission.hasPermission {
                    Label("Permission Granted", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .foregroundStyle(.green)
                        .frame(minHeight: 22)
                } else {
                    Button("Grant Permission") {
                        permission.performRequest()
                        Task {
                            await returnToWindow(once: permission)
                        }
                    }
                }

                if !permission.hasPermission {
                    // macOS ties the permission to the app's signature. After moving
                    // from Ice, or an update of an ad hoc signed build, the old entry
                    // stays enabled in System Settings but no longer applies to the
                    // new copy of the app, and macOS does not ask again.
                    Text("Already enabled in System Settings? Remove Icey from the list, then add it again.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Button("Reset and Ask Again") {
                        Task {
                            if await permission.resetAndRequest() {
                                failedResets.remove(permission.title)
                                await returnToWindow(once: permission)
                            } else {
                                failedResets.insert(permission.title)
                            }
                        }
                    }
                    .font(.callout)

                    if failedResets.contains(permission.title) {
                        Text("Icey couldn't reset the entry.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    Button("Open \(permission.title) Settings") {
                        permission.openPrivacyList()
                    }
                    .buttonStyle(.link)
                    .font(.callout)
                }

                if !permission.isRequired {
                    CalloutBox("Icey can work in a limited mode without this permission.") {
                        Image(systemName: "checkmark.shield")
                            .foregroundStyle(.green)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity)
        }
    }

    /// Brings the permissions window back to the front once the given
    /// permission is granted, if the window is still open.
    ///
    /// The user can continue, which closes the window, while a permission
    /// they asked for is still missing, and grant it later, such as Screen
    /// Recording from Icey's settings. Bringing the window back then gave
    /// Icey a Dock icon and showed the permissions window again, long after
    /// setup had finished.
    private func returnToWindow(once permission: Permission) async {
        await permission.waitForPermission()
        // The windows of a hidden app aren't visible, but stay open.
        guard
            NSApp.isHidden ||
            NSApp.window(withIdentifier: IceWindowIdentifier.permissions.rawValue)?.isVisible == true
        else {
            return
        }
        appState.activate(withPolicy: .regular)
        appState.openWindow(.permissions)
    }
}

/// Shows a permission detail as a secondary checkmark next to its text.
private struct PermissionDetailLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon
                .foregroundStyle(.secondary)
                .imageScale(.small)
            configuration.title
        }
    }
}
