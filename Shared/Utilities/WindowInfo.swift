//
//  WindowInfo.swift
//  Shared
//

import Cocoa

/// Information for a window.
struct WindowInfo {
    /// The window's identifier.
    let windowID: CGWindowID

    /// The identifier of the process that owns the window.
    let ownerPID: pid_t

    /// The window's bounds, specified in screen coordinates.
    let bounds: CGRect

    /// The window's layer number.
    let layer: Int

    /// The window's title.
    let title: String?

    /// The name of the process that owns the window.
    ///
    /// This may have a value when ``owningApplication`` does not have
    /// a localized name.
    let ownerName: String?

    /// A Boolean value that indicates whether the window is on screen.
    let isOnScreen: Bool

    /// The application that owns the window.
    var owningApplication: NSRunningApplication? {
        NSRunningApplication(processIdentifier: ownerPID)
    }

    /// A Boolean value that indicates whether the window belongs to the
    /// window server.
    var isWindowServerWindow: Bool {
        ownerName == "Window Server"
    }

    /// Creates a window with the given dictionary.
    private init?(dictionary: CFDictionary) {
        guard
            let info = dictionary as? [CFString: Any],
            let windowID = info[kCGWindowNumber] as? CGWindowID,
            let ownerPID = info[kCGWindowOwnerPID] as? pid_t,
            let boundsDict = info[kCGWindowBounds] as? NSDictionary,
            let bounds = CGRect(dictionaryRepresentation: boundsDict),
            let layer = info[kCGWindowLayer] as? Int
        else {
            return nil
        }
        self.windowID = windowID
        self.ownerPID = ownerPID
        self.bounds = bounds
        self.layer = layer
        self.title = info[kCGWindowName] as? String
        self.ownerName = info[kCGWindowOwnerName] as? String
        self.isOnScreen = info[kCGWindowIsOnscreen] as? Bool ?? false
    }

    /// Creates a window with the given window identifier.
    ///
    /// - Parameter windowID: A window identifier.
    init?(windowID: CGWindowID) {
        guard let window = WindowInfo.createWindows(from: [windowID]).first else {
            return nil
        }
        self = window
    }

    /// Returns the current bounds of the window.
    func currentBounds() -> CGRect? {
        Bridging.getWindowBounds(for: windowID)
    }
}

// MARK: - Window List

extension WindowInfo {
    /// Creates a list of windows from the given list of window identifiers.
    ///
    /// - Parameter windowIDs: A list of window identifiers.
    static func createWindows(from windowIDs: [CGWindowID]) -> [WindowInfo] {
        guard
            let array = Bridging.createCGWindowArray(with: windowIDs),
            let list = CGWindowListCreateDescriptionFromArray(array) as? [CFDictionary]
        else {
            return []
        }
        return list.compactMap { WindowInfo(dictionary: $0) }
    }

    /// Creates a list of windows using the given options.
    ///
    /// - Parameter option: Options that filter the returned list.
    ///   Pass an empty option set to return all available windows.
    static func createWindows(option: Bridging.WindowListOption = []) -> [WindowInfo] {
        createWindows(from: Bridging.getWindowList(option: option))
    }

    /// Creates a list of windows for the elements in the menu bar
    /// using the given options.
    ///
    /// - Parameter option: Options that filter the returned list.
    ///   Pass an empty option set to return all available windows.
    static func createMenuBarWindows(option: Bridging.MenuBarWindowListOption = []) -> [WindowInfo] {
        createWindows(from: Bridging.getMenuBarWindowList(option: option))
    }
}

// MARK: - Specific Windows

extension WindowInfo {
    /// Returns the wallpaper window for the given display from the
    /// given list of windows.
    static func wallpaperWindow(from windows: [WindowInfo], for display: CGDirectDisplayID) -> WindowInfo? {
        let displayBounds = CGDisplayBounds(display)
        // Wallpaper window belongs to the Dock process, or to WindowManager on
        // macOS 27 (measured on macOS 27.0 in jordanbaird/Ice#1001).
        let owner = if #available(macOS 27.0, *) { "com.apple.WindowManager" } else { "com.apple.dock" }
        let candidates = windows.filter { window in
            window.owningApplication?.bundleIdentifier == owner &&
            window.title?.hasPrefix("Wallpaper") == true &&
            displayBounds.contains(window.bounds)
        }
        // Each space has a wallpaper window of its own (measured on macOS 26.5:
        // one per space, each on that space only). While spaces change, more
        // than one can be on screen, and the first in the list could be the
        // previous space's, so the menu bar shape kept drawing the wallpaper of
        // the space the user had left (jordanbaird/Ice#336, #337). Prefer the
        // one on the space the display shows now.
        guard candidates.count > 1 else {
            return candidates.first
        }
        if
            let spaceID = Bridging.getCurrentSpaceID(for: display),
            spaceID != 0,
            let window = candidates.first(where: { Bridging.isWindowOnSpace($0.windowID, spaceID) })
        {
            return window
        }
        return candidates.first
    }

    /// Creates and returns the wallpaper window for the given display.
    static func wallpaperWindow(for display: CGDirectDisplayID) -> WindowInfo? {
        wallpaperWindow(from: createWindows(option: .onScreen), for: display)
    }

    /// Returns the window that darkens the top of the wallpaper behind the
    /// menu bar on the given display, from the given list of windows.
    ///
    /// On macOS 26, a window server window titled "underbelly" sits between the
    /// wallpaper and the menu bar, taller than the menu bar, and darkens the
    /// wallpaper there (measured on macOS 26.5.1: 83 points tall, average luma
    /// of the menu bar strip 121.7 without it and 109.4 with it). Returns `nil`
    /// where there is no such window.
    static func menuBarUnderbellyWindow(from windows: [WindowInfo], for display: CGDirectDisplayID) -> WindowInfo? {
        let displayBounds = CGDisplayBounds(display)
        return windows.first { window in
            window.isWindowServerWindow &&
            window.isOnScreen &&
            window.title == "underbelly" &&
            displayBounds.contains(window.bounds)
        }
    }

    // MARK: Menu Bar Window

    /// Returns the menu bar window for the given display from the
    /// given list of windows.
    static func menuBarWindow(from windows: [WindowInfo], for display: CGDirectDisplayID) -> WindowInfo? {
        let displayBounds = CGDisplayBounds(display)
        return windows.first { window in
            // Menu bar window belongs to the WindowServer process.
            window.isWindowServerWindow &&
            window.isOnScreen &&
            window.layer == kCGMainMenuWindowLevel &&
            window.title == "Menubar" &&
            displayBounds.contains(window.bounds)
        }
    }

    /// Creates and returns the menu bar window for the given display.
    static func menuBarWindow(for display: CGDirectDisplayID) -> WindowInfo? {
        menuBarWindow(from: createMenuBarWindows(option: .onScreen), for: display)
    }

    // MARK: Mission Control

    /// Returns a Boolean value that indicates whether Mission Control is open,
    /// judging by the given list of on screen windows.
    ///
    /// There is no public way to tell. While Mission Control is open, the Dock
    /// has an untitled window at the Dock's level covering the display, besides
    /// the Dock's own window, which also covers the display and is on screen
    /// whenever the Dock is (Mission Control always shows the Dock). Measured
    /// on macOS 26.5: there is no second such window with the Dock shown or
    /// hidden, in App Exposé or in Show Desktop, which put their window two
    /// levels lower. Titles are not compared, as reading them needs the Screen
    /// Recording permission. The windows are counted per display, so a Dock
    /// window on each of several displays is not taken for Mission Control.
    ///
    /// Call it only when an event calls for it, never per event or on a timer.
    static func isMissionControlActive(in windows: [WindowInfo]) -> Bool {
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        let dockLevelWindows = windows.filter { window in
            window.layer == dockLevel &&
            window.isOnScreen &&
            window.owningApplication?.bundleIdentifier == "com.apple.dock"
        }
        guard dockLevelWindows.count >= 2 else {
            return false
        }
        var displays = [CGDirectDisplayID](repeating: 0, count: 32)
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(displays.count), &displays, &displayCount) == .success else {
            return false
        }
        return displays.prefix(Int(displayCount)).contains { display in
            let displayBounds = CGDisplayBounds(display)
            return dockLevelWindows.filter { $0.bounds.contains(displayBounds) }.count >= 2
        }
    }
}

// MARK: WindowInfo: Codable
extension WindowInfo: Codable { }

// MARK: WindowInfo: Equatable
extension WindowInfo: Equatable {
    static func == (lhs: WindowInfo, rhs: WindowInfo) -> Bool {
        lhs.windowID == rhs.windowID &&
        lhs.ownerPID == rhs.ownerPID &&
        NSStringFromRect(lhs.bounds) == NSStringFromRect(rhs.bounds) &&
        lhs.layer == rhs.layer &&
        lhs.title == rhs.title &&
        lhs.ownerName == rhs.ownerName &&
        lhs.isOnScreen == rhs.isOnScreen
    }
}

// MARK: WindowInfo: Hashable
extension WindowInfo: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(windowID)
        hasher.combine(ownerPID)
        hasher.combine(NSStringFromRect(bounds))
        hasher.combine(layer)
        hasher.combine(title)
        hasher.combine(ownerName)
        hasher.combine(isOnScreen)
    }
}
