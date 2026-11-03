//
//  URLCommand.swift
//  Ice
//

import AppKit
import OSLog

/// A command sent to Icey with an `icey://` URL, so that Shortcuts, scripts,
/// launchers such as Raycast and Alfred, and other apps can control it
/// (jordanbaird/Ice#141, #148, #382, #501, #516).
///
/// The URL's host names the command, for example `icey://toggle-hidden` or,
/// from Terminal, `open icey://search`. Unknown commands are ignored.
enum URLCommand: String, CaseIterable {
    case toggleHidden = "toggle-hidden"
    case showHidden = "show-hidden"
    case hideHidden = "hide-hidden"
    case toggleAlwaysHidden = "toggle-always-hidden"
    case showAlwaysHidden = "show-always-hidden"
    case hideAlwaysHidden = "hide-always-hidden"
    case search
    case toggleIceBar = "toggle-ice-bar"
    case toggleApplicationMenus = "toggle-application-menus"
    case settings

    /// The URL scheme Icey registers, in `Info.plist`.
    static let scheme = "icey"

    private static let logger = Logger(category: "URLCommand")

    /// Creates the command that the given URL names, or `nil` if it names none.
    init?(url: URL) {
        guard
            url.scheme?.lowercased() == Self.scheme,
            let host = url.host(percentEncoded: false)?.lowercased()
        else {
            return nil
        }
        self.init(rawValue: host)
    }

    /// Performs the commands named by the given URLs.
    @MainActor
    static func handle(_ urls: [URL], appState: AppState) {
        for url in urls {
            guard let command = URLCommand(url: url) else {
                logger.notice("Ignoring unknown URL command \(url.absoluteString, privacy: .public)")
                continue
            }
            logger.info("Performing URL command \(command.rawValue, privacy: .public)")
            command.perform(appState: appState)
        }
    }

    /// Performs the command.
    @MainActor
    func perform(appState: AppState) {
        switch self {
        case .toggleHidden:
            HotkeyAction.toggleHiddenSection.perform(appState: appState)
        case .showHidden:
            show(.hidden, appState: appState)
        case .hideHidden:
            appState.menuBarManager.section(withName: .hidden)?.hide()
        case .toggleAlwaysHidden:
            HotkeyAction.toggleAlwaysHiddenSection.perform(appState: appState)
        case .showAlwaysHidden:
            show(.alwaysHidden, appState: appState)
        case .hideAlwaysHidden:
            appState.menuBarManager.section(withName: .alwaysHidden)?.hide()
        case .search:
            appState.menuBarManager.searchPanel.show()
        case .toggleIceBar:
            HotkeyAction.enableIceBar.perform(appState: appState)
        case .toggleApplicationMenus:
            HotkeyAction.toggleApplicationMenus.perform(appState: appState)
        case .settings:
            appState.activateAndOpenSettings()
        }
    }

    /// Shows the section with the given name, like its hotkey does.
    @MainActor
    private func show(_ name: MenuBarSection.Name, appState: AppState) {
        guard
            let section = appState.menuBarManager.section(withName: name),
            section.isEnabled,
            section.isHidden
        else {
            return
        }
        section.show()
        // As with the hotkey, moving the pointer away doesn't hide it again.
        appState.menuBarManager.showOnHoverAllowed = false
    }
}
