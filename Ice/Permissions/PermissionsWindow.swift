//
//  PermissionsWindow.swift
//  Ice
//

import SwiftUI

struct PermissionsWindow: Scene {
    let appState: AppState

    var body: some Scene {
        IceWindow(id: .permissions) {
            PermissionsView()
                .presentedWhileWindowIsOpen(.permissions)
                .onWindowChange { window in
                    guard let window else {
                        return
                    }
                    window.standardWindowButton(.closeButton)?.isHidden = true
                    window.standardWindowButton(.miniaturizeButton)?.isHidden = true
                    window.standardWindowButton(.zoomButton)?.isHidden = true
                    if let contentView = window.contentView {
                        withMutableCopy(of: contentView.safeAreaInsets) { insets in
                            insets.bottom = -insets.bottom
                            insets.left = -insets.left
                            insets.right = -insets.right
                            insets.top = -insets.top
                            contentView.additionalSafeAreaInsets = insets
                        }
                    }
                }
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .environmentObject(appState)
        .environmentObject(appState.permissions)
    }
}
