//
//  Bridging.swift
//  Shared
//

import Cocoa
import OSLog

// MARK: - Bridging

/// A namespace for bridged or wrapped APIs.
enum Bridging {
    private static let logger = Logger(category: "Bridging")
}

// MARK: - CGSConnection

extension Bridging {

    // MARK: Private Connection Helpers

    /// The identifier for the `null` window server connection.
    private static let nullConnection: CGSConnectionID = 0

    /// Returns the identifier for the main window server connection.
    private static func getMainConnection() -> CGSConnectionID {
        CGSMainConnectionID()
    }

    /// Returns the identifier for the window server connection
    /// for the current thread.
    private static func getConnectionForThread() -> CGSConnectionID {
        CGSDefaultConnectionForThread()
    }

    // MARK: Public Connection API

    /// Returns a value from the main window server connection.
    ///
    /// - Parameter key: A key associated with a value in the main
    ///   window server connection.
    static func getConnectionProperty(forKey key: String) -> Any? {
        var value: Unmanaged<CFTypeRef>?
        let result = CGSCopyConnectionProperty(
            getMainConnection(),
            getMainConnection(),
            key as CFString,
            &value
        )
        if result != .success {
            logger.error("CGSCopyConnectionProperty failed with error \(result.logString, privacy: .public)")
        }
        return value?.takeRetainedValue()
    }

    /// Sets a value in the main window server connection.
    ///
    /// - Parameters:
    ///   - value: A value to set.
    ///   - key: A key to associate with `value` as a property in the
    ///     main window server connection.
    static func setConnectionProperty(_ value: Any?, forKey key: String) {
        let result = CGSSetConnectionProperty(
            getMainConnection(),
            getMainConnection(),
            key as CFString,
            value as CFTypeRef
        )
        if result != .success {
            logger.error("CGSSetConnectionProperty failed with error \(result.logString, privacy: .public)")
        }
    }
}

// MARK: - CGDisplay / CGSDisplay

extension Bridging {

    // MARK: Private Display Helpers

    private static func getActiveDisplayCount() -> UInt32? {
        var count: UInt32 = 0
        let result = CGGetActiveDisplayList(0, nil, &count)
        guard result == .success else {
            logger.error("CGGetActiveDisplayList failed with error \(result.logString, privacy: .public)")
            return nil
        }
        return count
    }

    private static func getActiveDisplayList() -> [CGDirectDisplayID] {
        guard let count = getActiveDisplayCount() else {
            return []
        }
        var list = [CGDirectDisplayID](repeating: 0, count: Int(count))
        let result = CGGetActiveDisplayList(count, &list, nil)
        guard result == .success else {
            logger.error("CGGetActiveDisplayList failed with error \(result.logString, privacy: .public)")
            return []
        }
        return list
    }

    private static func getDisplayUUID(for displayID: CGDirectDisplayID) -> CFUUID? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID) else {
            logger.error("CGDisplayCreateUUIDFromDisplayID returned nil for display \(displayID, privacy: .public)")
            return nil
        }
        return uuid.takeRetainedValue()
    }

    // MARK: Public Display API

    /// Returns the identifier of the display with the active menu bar.
    static func getActiveMenuBarDisplayID() -> CGDirectDisplayID? {
        if
            let string = CGSCopyActiveMenuBarDisplayIdentifier(getMainConnection()),
            let uuid = CFUUIDCreateFromString(nil, string.takeRetainedValue()),
            let displayID = getActiveDisplayList().first(where: { getDisplayUUID(for: $0) == uuid })
        {
            return displayID
        }
        // CGSCopyActiveMenuBarDisplayIdentifier can return nil on macOS 26.4 and
        // later. Without a display, no menu bar item images are ever cached, so
        // fall back to the main display.
        let displayID = CGMainDisplayID()
        logger.warning("Could not get display with active menu bar, using main display \(displayID, privacy: .public)")
        return displayID
    }
}

// MARK: - CGSEvent

extension Bridging {
    /// Returns a Boolean value indicating whether the given process
    /// is unresponsive.
    ///
    /// - Parameter pid: An identifier for a process.
    static func isProcessUnresponsive(_ pid: pid_t) -> Bool {
        var psn = ProcessSerialNumber()
        let result = GetProcessForPID(pid, &psn)
        guard result == noErr else {
            logger.error("GetProcessForPID failed with error \(result, privacy: .public)")
            return false
        }
        return CGSEventIsAppUnresponsive(getMainConnection(), &psn)
    }

    /// Sets the timeout used to determine if a process is unresponsive.
    ///
    /// - Parameter timeout: An amount of time in seconds.
    static func setProcessUnresponsiveTimeout(_ timeout: TimeInterval) {
        let result = CGSEventSetAppIsUnresponsiveNotificationTimeout(getMainConnection(), timeout)
        if result != .success {
            logger.error("CGSEventSetAppIsUnresponsiveNotificationTimeout failed with error \(result.logString, privacy: .public)")
        }
    }
}

// MARK: - CGSSpace

extension Bridging {
    /// Returns the identifier for the active space.
    static func getActiveSpaceID() -> CGSSpaceID {
        CGSGetActiveSpace(getMainConnection())
    }

    /// Returns the identifier for the current space on the given
    /// display.
    ///
    /// - Parameter displayID: An identifier for a display.
    static func getCurrentSpaceID(for displayID: CGDirectDisplayID) -> CGSSpaceID? {
        guard let uuid = getDisplayUUID(for: displayID) else {
            return nil
        }
        guard let uuidString = CFUUIDCreateString(nil, uuid) else {
            logger.error("CFUUIDCreateString returned nil for display \(displayID, privacy: .public)")
            return nil
        }
        return CGSManagedDisplayGetCurrentSpace(getMainConnection(), uuidString)
    }

    /// Returns a list of identifiers for the spaces that contain the
    /// given window.
    ///
    /// - Parameters:
    ///   - windowID: An identifier for a window.
    ///   - visibleSpacesOnly: A Boolean value that determines whether
    ///     the returned list should only include visible spaces.
    static func getSpaceList(for windowID: CGWindowID, visibleSpacesOnly: Bool = false) -> [CGSSpaceID] {
        let mask: CGSSpaceMask = visibleSpacesOnly ? .allVisibleSpacesMask : .allSpacesMask
        guard let spaces = CGSCopySpacesForWindows(getMainConnection(), mask, [windowID] as CFArray) else {
            logger.error("CGSCopySpacesForWindows returned nil")
            return []
        }
        guard let list = spaces.takeRetainedValue() as? [CGSSpaceID] else {
            logger.error("CGSCopySpacesForWindows returned array of unexpected type")
            return []
        }
        return list
    }

    /// Returns a Boolean value that indicates whether the given space
    /// is fullscreen.
    ///
    /// - Parameter spaceID: An identifier for a space.
    static func isSpaceFullscreen(_ spaceID: CGSSpaceID) -> Bool {
        let type = CGSSpaceGetType(getMainConnection(), spaceID)
        return type == CGSSpaceType.fullscreen.rawValue
    }
}

// MARK: - CGSWindow

extension Bridging {
    /// Supplies bounds for identifiers that are not WindowServer windows.
    ///
    /// On macOS 27, menu bar items read through Accessibility carry synthetic
    /// identifiers with the top bit set.
    nonisolated(unsafe) static var syntheticWindowBoundsProvider: ((CGWindowID) -> CGRect?)?

    /// Returns the bounds for the given window.
    ///
    /// - Parameter windowID: An identifier for a window.
    static func getWindowBounds(for windowID: CGWindowID) -> CGRect? {
        if windowID & 0x8000_0000 != 0, let syntheticWindowBoundsProvider {
            return syntheticWindowBoundsProvider(windowID)
        }
        var bounds = CGRect.zero
        let result = CGSGetScreenRectForWindow(getConnectionForThread(), windowID, &bounds)
        guard result == .success else {
            logger.error("CGSGetScreenRectForWindow failed with error \(result.logString, privacy: .public)")
            return nil
        }
        return bounds
    }

    /// Returns the level for the given window.
    ///
    /// - Parameter windowID: An identifier for a window.
    static func getWindowLevel(for windowID: CGWindowID) -> CGWindowLevel? {
        var level: CGWindowLevel = 0
        let result = CGSGetWindowLevel(getMainConnection(), windowID, &level)
        guard result == .success else {
            logger.error("CGSGetWindowLevel failed with error \(result.logString, privacy: .public)")
            return nil
        }
        return level
    }

    /// Returns a Boolean value that indicates whether the given window
    /// is on the given space.
    ///
    /// - Parameters:
    ///   - windowID: An identifier for a window.
    ///   - spaceID: An identifier for a space.
    static func isWindowOnSpace(_ windowID: CGWindowID, _ spaceID: CGSSpaceID) -> Bool {
        let list = getSpaceList(for: windowID, visibleSpacesOnly: false)
        return list.contains(spaceID)
    }

    /// Returns a Boolean value that indicates whether the given window
    /// intersects the given display bounds.
    ///
    /// - Parameters:
    ///   - windowID: An identifier for a window.
    ///   - displayBounds: The bounds of a display.
    static func windowIntersectsDisplayBounds(_ windowID: CGWindowID, _ displayBounds: CGRect) -> Bool {
        if let windowBounds = getWindowBounds(for: windowID) {
            return displayBounds.intersects(windowBounds)
        }
        return false
    }

    /// Returns a Boolean value that indicates whether the given window
    /// is on the specified display.
    ///
    /// - Parameters:
    ///   - windowID: An identifier for a window.
    ///   - displayID: An identifier for a display.
    static func isWindowOnDisplay(_ windowID: CGWindowID, _ displayID: CGDirectDisplayID) -> Bool {
        let displayBounds = CGDisplayBounds(displayID)
        return windowIntersectsDisplayBounds(windowID, displayBounds)
    }

    /// Returns a Boolean value that indicates whether the given window
    /// is on screen.
    ///
    /// - Parameter windowID: An identifier for a window.
    static func isWindowOnScreen(_ windowID: CGWindowID) -> Bool {
        // On screen window list could potentially include menu bar
        // items hidden via drag-and-drop (seems like a bug in macOS?).
        //
        // Checking individual displays could be relatively expensive,
        // so we can at least short circuit if the window is _not_ in
        // the list.
        if !getOnScreenWindowList().contains(windowID) {
            return false
        }
        guard let windowBounds = getWindowBounds(for: windowID) else {
            return false
        }
        return getActiveDisplayList().contains { displayID in
            let displayBounds = CGDisplayBounds(displayID)
            return displayBounds.intersects(windowBounds)
        }
    }

    // MARK: Private Window List Helpers

    private static func getWindowCount() -> Int32? {
        var count: Int32 = 0
        let result = CGSGetWindowCount(getMainConnection(), nullConnection, &count)
        guard result == .success else {
            logger.error("CGSGetWindowCount failed with error \(result.logString, privacy: .public)")
            return nil
        }
        return count
    }

    private static func getOnScreenWindowCount() -> Int32? {
        var count: Int32 = 0
        let result = CGSGetOnScreenWindowCount(getMainConnection(), nullConnection, &count)
        guard result == .success else {
            logger.error("CGSGetOnScreenWindowCount failed with error \(result.logString, privacy: .public)")
            return nil
        }
        return count
    }

    private static func getWindowList() -> [CGWindowID] {
        guard var count = getWindowCount() else {
            return []
        }
        var list = [CGWindowID](repeating: 0, count: Int(count))
        let result = CGSGetWindowList(getMainConnection(), nullConnection, count, &list, &count)
        guard result == .success else {
            logger.error("CGSGetWindowList failed with error \(result.logString, privacy: .public)")
            return []
        }
        return [CGWindowID](list[..<Int(count)])
    }

    private static func getOnScreenWindowList() -> [CGWindowID] {
        guard var count = getOnScreenWindowCount() else {
            return []
        }
        var list = [CGWindowID](repeating: 0, count: Int(count))
        let result = CGSGetOnScreenWindowList(getMainConnection(), nullConnection, count, &list, &count)
        guard result == .success else {
            logger.error("CGSGetOnScreenWindowList failed with error \(result.logString, privacy: .public)")
            return []
        }
        return [CGWindowID](list[..<Int(count)])
    }

    private static func getProcessMenuBarWindowList() -> [CGWindowID] {
        guard var count = getWindowCount() else {
            return []
        }
        var list = [CGWindowID](repeating: 0, count: Int(count))
        let result = CGSGetProcessMenuBarWindowList(getMainConnection(), nullConnection, count, &list, &count)
        guard result == .success else {
            logger.error("CGSGetProcessMenuBarWindowList failed with error \(result.logString, privacy: .public)")
            return []
        }
        return [CGWindowID](list[..<Int(count)])
    }

    // MARK: Public Window List API

    /// Options that specify the identifiers in a window list.
    struct WindowListOption: OptionSet {
        let rawValue: Int

        /// Specifies windows that are currently on screen.
        static let onScreen = WindowListOption(rawValue: 1 << 0)

        /// Specifies windows on the currently active space.
        static let activeSpace = WindowListOption(rawValue: 1 << 1)
    }

    /// Options that specify the identifiers in a menu bar window list.
    struct MenuBarWindowListOption: OptionSet {
        let rawValue: Int

        /// Specifies windows that are currently on screen.
        static let onScreen = MenuBarWindowListOption(rawValue: 1 << 0)

        /// Specifies windows on the currently active space.
        static let activeSpace = MenuBarWindowListOption(rawValue: 1 << 1)

        /// Specifies only windows that represent menu bar items.
        static let itemsOnly = MenuBarWindowListOption(rawValue: 1 << 2)
    }

    /// Returns a list of window identifiers.
    ///
    /// - Parameter option: Options that filter the returned list.
    ///   Pass an empty option set to return all available windows.
    static func getWindowList(option: WindowListOption = []) -> [CGWindowID] {
        let list = if option.contains(.onScreen) {
            getOnScreenWindowList()
        } else {
            getWindowList()
        }
        if option.contains(.activeSpace) {
            let activeSpaceID = getActiveSpaceID()
            return list.filter { windowID in
                isWindowOnSpace(windowID, activeSpaceID)
            }
        }
        return list
    }

    /// Returns a list of window identifiers for elements in the
    /// menu bar.
    ///
    /// - Parameter option: Options that filter the returned list.
    ///   Pass an empty option set to return all available windows.
    static func getMenuBarWindowList(option: MenuBarWindowListOption = []) -> [CGWindowID] {
        var predicates = [(CGWindowID) -> Bool]()

        if option.contains(.onScreen) {
            let onScreenList = Set(getOnScreenWindowList())
            predicates.append { windowID in
                onScreenList.contains(windowID)
            }
        }

        let activeSpaceID = option.contains(.activeSpace) ? getActiveSpaceID() : nil

        if option.contains(.itemsOnly) {
            predicates.append { windowID in
                getWindowLevel(for: windowID) != kCGMainMenuWindowLevel
            }
        }

        let list = getProcessMenuBarWindowList().filter { windowID in
            predicates.allSatisfy { predicate in
                predicate(windowID)
            }
        }

        if let activeSpaceID {
            return windows(in: list, onSpace: activeSpaceID)
        }
        return list
    }

    /// Returns the windows in the given list that are on the given space,
    /// in the same order.
    ///
    /// The result is the same as checking each window with ``isWindowOnSpace(_:_:)``,
    /// which asks the window server once per window. This asks for the
    /// space's window list once instead, and checks the windows that are not
    /// in it with one more call.
    ///
    /// The space's window list (`CGSCopyWindowsWithOptionsAndTags` with
    /// options 0x7, as yabai, Hammerspoon and alt-tab-macos call it) never
    /// held a window that `CGSCopySpacesForWindows` placed on another space,
    /// but it can leave out a window that is on the space. Measured on macOS
    /// 26.5.1, over 370 windows and 7 spaces: no window was listed that was
    /// not on the space, and one window, assigned to every space, was not
    /// listed. Options 0 and 2 leave out the menu bar items that are hidden.
    /// So the windows the list leaves out are checked as well, all with one
    /// `CGSCopySpacesForWindows` call, which returns the spaces of all the
    /// windows it is given. Only if one of them is on the space are they
    /// checked one by one. With separate spaces per display, these are the
    /// item windows of the other displays.
    ///
    /// - Parameters:
    ///   - list: A list of window identifiers.
    ///   - spaceID: An identifier for a space.
    private static func windows(in list: [CGWindowID], onSpace spaceID: CGSSpaceID) -> [CGWindowID] {
        guard !list.isEmpty else {
            return list
        }

        var setTags: UInt64 = 0
        var clearTags: UInt64 = 0
        guard
            let spaceWindows = CGSCopyWindowsWithOptionsAndTags(
                getMainConnection(),
                0,
                [spaceID] as CFArray,
                0x7,
                &setTags,
                &clearTags
            ),
            let spaceList = spaceWindows.takeRetainedValue() as? [CGWindowID]
        else {
            logger.error("CGSCopyWindowsWithOptionsAndTags returned nil, checking each window")
            return list.filter { windowID in
                isWindowOnSpace(windowID, spaceID)
            }
        }

        let listed = Set(spaceList)
        let unlisted = list.filter { !listed.contains($0) }
        var alsoOnSpace = Set<CGWindowID>()

        if !unlisted.isEmpty {
            let unlistedSpaces = CGSCopySpacesForWindows(getMainConnection(), .allSpacesMask, unlisted as CFArray)
            let spaces = unlistedSpaces?.takeRetainedValue() as? [CGSSpaceID]
            // If the call fails, check each window, as before.
            if spaces?.contains(spaceID) ?? true {
                alsoOnSpace = Set(unlisted.filter { windowID in
                    isWindowOnSpace(windowID, spaceID)
                })
            }
        }

        let result = list.filter { windowID in
            listed.contains(windowID) || alsoOnSpace.contains(windowID)
        }

        #if DEBUG
        // The option bits are private. Compare with the per-window check, so
        // a difference on another macOS version shows up in development. A
        // space change between the calls can also make them differ.
        let expected = list.filter { windowID in
            isWindowOnSpace(windowID, spaceID)
        }
        if result != expected {
            logger.fault("Batched space filter differs from per-window check on space \(spaceID, privacy: .public): \(result, privacy: .public) vs \(expected, privacy: .public)")
        }
        #endif

        return result
    }

    // MARK: - CGWindowList Helpers

    /// Creates a `CFArray` containing the bit patterns of the given
    /// window list.
    ///
    /// Pass the returned array into one of the `CGWindowList` APIs
    /// from `CoreGraphics`.
    ///
    /// - Parameter windowIDs: A list of window identifiers. If the
    ///   list is empty, or if none of its elements can represent a
    ///   valid bit pattern, this function returns `nil`.
    ///
    /// - Returns: A `CFArray` where each element is a memory address
    ///   with a bit pattern that matches an element from `windowIDs`,
    ///   or `nil` if the array cannot be created.
    static func createCGWindowArray(with windowIDs: [CGWindowID]) -> CFArray? {
        var pointers: [UnsafeRawPointer?] = windowIDs.compactMap { windowID in
            UnsafeRawPointer(bitPattern: UInt(windowID))
        }
        guard
            !pointers.isEmpty,
            let array = CFArrayCreate(nil, &pointers, pointers.count, nil)
        else {
            return nil
        }
        return array
    }
}
