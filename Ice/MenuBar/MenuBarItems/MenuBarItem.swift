//
//  MenuBarItem.swift
//  Ice
//

import Cocoa
import os.lock

/// A structural representation of a menu bar item.
struct MenuBarItem: CustomStringConvertible {
    /// The tag associated with this item.
    let tag: MenuBarItemTag

    /// The item's window identifier.
    let windowID: CGWindowID

    /// The identifier of the process that owns the item.
    let ownerPID: pid_t

    /// The identifier of the process that created the item.
    let sourcePID: pid_t?

    /// The item's bounds, specified in screen coordinates.
    let bounds: CGRect

    /// The item's window title.
    let title: String?

    /// A Boolean value that indicates whether the item is on screen.
    let isOnScreen: Bool

    /// A Boolean value that indicates whether this item can be moved.
    var isMovable: Bool {
        tag.isMovable
    }

    /// A Boolean value that indicates whether this item can be hidden.
    var canBeHidden: Bool {
        tag.canBeHidden
    }

    /// A Boolean value that indicates whether this item is one of Ice's
    /// control items.
    var isControlItem: Bool {
        tag.isControlItem
    }

    /// A Boolean value that indicates whether this item is a "BentoBox"
    /// item owned by the Control Center.
    var isBentoBox: Bool {
        tag.isBentoBox
    }

    /// A Boolean value that indicates whether this item is a
    /// system-created clone of an actual item, and therefore invalid
    /// for management.
    var isSystemClone: Bool {
        tag.isSystemClone
    }

    /// The application that owns the item.
    ///
    /// - Note: In macOS 26 and later, this property always returns the
    ///   Control Center. To get the actual application that created the
    ///   item, use ``sourceApplication``.
    var owningApplication: NSRunningApplication? {
        NSRunningApplication(processIdentifier: ownerPID)
    }

    /// The application that created the item.
    ///
    /// - Note: Prior to macOS 26, this property and ``owningApplication``
    ///   are functionally equivalent.
    var sourceApplication: NSRunningApplication? {
        guard let sourcePID else {
            return nil
        }
        return NSRunningApplication(processIdentifier: sourcePID)
    }

    // TODO: Generate this once, during initialization.
    /// A name associated with the item, suited for display.
    var displayName: String {
        /// Converts "UpperCamelCase" to "Title Case".
        ///
        /// Ignores cases where a single lowercase letter immediately
        /// precedes an uppercase letter (i.e. "WiFi").
        func toTitleCase<S: StringProtocol>(_ s: S) -> String {
            String(s).replacing(/([a-z]{2})([A-Z])/) { $0.output.1 + " " + $0.output.2 }
        }

        guard !isControlItem else {
            return Constants.displayName
        }

        lazy var fallbackName = String(localized: "Menu Bar Item")

        guard let sourceApplication else {
            return fallbackName
        }

        lazy var sourceName = sourceApplication.localizedName ?? sourceApplication.bundleIdentifier

        guard let title else {
            return sourceName ?? fallbackName
        }

        lazy var bestName = sourceName ?? title

        guard !isBentoBox else {
            if tag == .controlCenter {
                return bestName
            }
            return title
        }

        // Most items use their computed "best name", but we handle
        // a few special cases for system items.
        let displayName = switch tag.namespace {
        case .passwords, .weather, .textInputMenuAgent:
            // "PasswordsMenuBarExtra" -> "Passwords"
            // "WeatherMenu" -> "Weather"
            // "TextInputMenuAgent" -> "Text Input"
            toTitleCase(bestName.replacing(/Menu.*/, with: ""))
        case .controlCenter:
            if let match = title.prefixMatch(of: /Hearing/) {
                // Changed from "Hearing" to "Hearing_GlowE" in macOS 15.4
                toTitleCase(match.output)
            } else {
                toTitleCase(title)
            }
        case .systemUIServer:
            if let match = title.firstMatch(of: /TimeMachine/) {
                // Sonoma:  "TimeMachine.TMMenuExtraHost"
                // Sequoia: "TimeMachineMenuExtra.TMMenuExtraHost"
                // Tahoe:   "com.apple.menuextra.TimeMachine"
                toTitleCase(match.output)
            } else {
                toTitleCase(title)
            }
        default:
            bestName
        }

        // Provide some extra context if the name is just a UUID.
        if UUID(uuidString: displayName) != nil, let sourceName {
            return "\(sourceName) (\(displayName))"
        }

        return displayName
    }

    /// A textual representation of the item.
    var description: String {
        "\(displayName) (\(tag))"
    }

    /// A string to use for logging purposes.
    var logString: String {
        "<\(tag) (windowID: \(windowID))>"
    }

    /// Creates a menu bar item without checks.
    ///
    /// This initializer does not perform validity checks on its parameters.
    /// Only call it if you are certain the window is a valid menu bar item.
    private init(uncheckedItemWindow itemWindow: WindowInfo, applications: inout RunningApplicationLookup) {
        self.tag = MenuBarItemTag(uncheckedItemWindow: itemWindow, applications: &applications)
        self.windowID = itemWindow.windowID
        self.ownerPID = itemWindow.ownerPID
        self.sourcePID = itemWindow.ownerPID
        self.bounds = itemWindow.bounds
        self.title = itemWindow.title
        self.isOnScreen = itemWindow.isOnScreen
    }

    /// Creates a menu bar item without checks.
    ///
    /// This initializer does not perform validity checks on its parameters.
    /// Only call it if you are certain the window is a valid menu bar item
    /// and the source pid belongs to the application that created it.
    @available(macOS 26.0, *)
    private init(uncheckedItemWindow itemWindow: WindowInfo, sourcePID: pid_t?, applications: inout RunningApplicationLookup) {
        self.tag = MenuBarItemTag(uncheckedItemWindow: itemWindow, sourcePID: sourcePID, applications: &applications)
        self.windowID = itemWindow.windowID
        self.ownerPID = itemWindow.ownerPID
        self.sourcePID = sourcePID
        self.bounds = itemWindow.bounds
        self.title = itemWindow.title
        self.isOnScreen = itemWindow.isOnScreen
    }
}

// MARK: - MenuBarItem List

extension MenuBarItem {
    /// Options that specify the menu bar items in a list.
    struct ListOption: OptionSet {
        let rawValue: Int

        /// Specifies menu bar items that are currently on screen.
        static let onScreen = ListOption(rawValue: 1 << 0)

        /// Specifies menu bar items on the currently active space.
        static let activeSpace = ListOption(rawValue: 1 << 1)
    }

    /// Creates and returns a list of menu bar items windows for the given display.
    ///
    /// - Parameters:
    ///   - display: An identifier for a display. Pass `nil` to return the menu bar
    ///     item windows across all available displays.
    ///   - option: Options that filter the returned list. Pass an empty option set
    ///     to return all available menu bar item windows.
    static func getMenuBarItemWindows(on display: CGDirectDisplayID? = nil, option: ListOption) -> [WindowInfo] {
        var bridgingOption: Bridging.MenuBarWindowListOption = .itemsOnly
        var displayBoundsPredicate: (WindowInfo) -> Bool = { _ in true }

        if let display {
            bridgingOption.insert(.onScreen)
            let displayBounds = CGDisplayBounds(display)
            displayBoundsPredicate = { window in
                displayBounds.intersects(window.bounds)
            }
        } else if option.contains(.onScreen) {
            bridgingOption.insert(.onScreen)
        }
        if option.contains(.activeSpace) {
            bridgingOption.insert(.activeSpace)
        }

        let windowIDs = Bridging.getMenuBarWindowList(option: bridgingOption)

        // Retrieve the window descriptions in a single call to the window server,
        // rather than one call per window, as this is called on hot paths, such
        // as drawing the split shape of the menu bar appearance.
        let windows = WindowInfo.createWindows(from: windowIDs).reduce(into: [CGWindowID: WindowInfo]()) { result, window in
            result[window.windowID] = window
        }

        return windowIDs.reversed().compactMap { windowID in
            guard
                let window = windows[windowID],
                displayBoundsPredicate(window)
            else {
                return nil
            }
            return window
        }
    }

    /// Creates and returns a list of menu bar items using experimental
    /// source pid retrieval for macOS 26.
    @available(macOS 26.0, *)
    private static func getMenuBarItemsExperimental(on display: CGDirectDisplayID?, option: ListOption) async -> [MenuBarItem] {
        var items = [MenuBarItem]()
        var applications = RunningApplicationLookup()
        let windows = getMenuBarItemWindows(on: display, option: option)
        let sourcePIDs = await MenuBarItemService.Connection.shared.sourcePIDs(for: windows)
        for (window, sourcePID) in zip(windows, sourcePIDs) {
            let item = MenuBarItem(uncheckedItemWindow: window, sourcePID: sourcePID, applications: &applications)
            items.append(item)
        }
        return items
    }

    /// Creates and returns a list of menu bar items, defaulting to the
    /// legacy source pid behavior, prior to macOS 26.
    private static func getMenuBarItemsLegacyMethod(on display: CGDirectDisplayID?, option: ListOption) -> [MenuBarItem] {
        var applications = RunningApplicationLookup()
        return getMenuBarItemWindows(on: display, option: option).map { window in
            MenuBarItem(uncheckedItemWindow: window, applications: &applications)
        }
    }

    /// Creates and returns a list of menu bar items for the given display.
    ///
    /// - Parameters:
    ///   - display: An identifier for a display. Pass `nil` to return the menu bar
    ///     items across all available displays.
    ///   - option: Options that filter the returned list. Pass an empty option set
    ///     to return all available menu bar items.
    static func getMenuBarItems(on display: CGDirectDisplayID? = nil, option: ListOption) async -> [MenuBarItem] {
        if #available(macOS 27.0, *) {
            // Accessibility only describes the display with the active menu bar.
            if let display, display != Bridging.getActiveMenuBarDisplayID() {
                return []
            }
            let items = await MenuBarItemProvider27.items()
            return option.contains(.onScreen) ? items.filter(\.isOnScreen) : items
        } else if #available(macOS 26.0, *) {
            return await getMenuBarItemsExperimental(on: display, option: option)
        } else {
            return getMenuBarItemsLegacyMethod(on: display, option: option)
        }
    }
}

// MARK: MenuBarItem: Equatable
extension MenuBarItem: Equatable {
    static func == (lhs: MenuBarItem, rhs: MenuBarItem) -> Bool {
        lhs.tag == rhs.tag &&
        lhs.windowID == rhs.windowID &&
        lhs.ownerPID == rhs.ownerPID &&
        lhs.sourcePID == rhs.sourcePID &&
        haveEqualDescriptions(lhs.bounds, rhs.bounds) &&
        lhs.title == rhs.title &&
        lhs.isOnScreen == rhs.isOnScreen
    }

    /// Returns a Boolean value that indicates whether `NSStringFromRect`
    /// describes the given rectangles with the same string, which is how
    /// items compare their bounds.
    ///
    /// Formatting both rectangles is the slow part of comparing two items,
    /// and the item caches compare the same items again and again. Values
    /// with identical bits always format identically, so only rectangles that
    /// differ are formatted. Comparing the values themselves would not give
    /// the same results: `==` treats `0` and `-0` as equal and `nan` as unequal
    /// to itself, while their strings say the opposite, and values that differ
    /// only past the sixth significant digit have the same string.
    private static func haveEqualDescriptions(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        if
            lhs.origin.x.bitPattern == rhs.origin.x.bitPattern,
            lhs.origin.y.bitPattern == rhs.origin.y.bitPattern,
            lhs.size.width.bitPattern == rhs.size.width.bitPattern,
            lhs.size.height.bitPattern == rhs.size.height.bitPattern
        {
            return true
        }
        return NSStringFromRect(lhs) == NSStringFromRect(rhs)
    }
}

// MARK: MenuBarItem: Hashable
extension MenuBarItem: Hashable {
    func hash(into hasher: inout Hasher) {
        // The bounds are left out: hashing their description cost as much as
        // comparing it, and items that are equal have equal bounds anyway.
        hasher.combine(tag)
        hasher.combine(windowID)
        hasher.combine(ownerPID)
        hasher.combine(sourcePID)
        hasher.combine(title)
        hasher.combine(isOnScreen)
    }
}

// MARK: - MenuBarItemTag Helper

private extension MenuBarItemTag {
    /// Creates a tag without checks.
    ///
    /// This initializer does not perform validity checks on its parameters.
    /// Only call it if you are certain the window is a valid menu bar item.
    init(uncheckedItemWindow itemWindow: WindowInfo, applications: inout RunningApplicationLookup) {
        self.namespace = Namespace(uncheckedItemWindow: itemWindow, applications: &applications)
        self.title = itemWindow.title ?? ""
    }

    /// Creates a tag without checks.
    ///
    /// This initializer does not perform validity checks on its parameters.
    /// Only call it if you are certain the window is a valid menu bar item
    /// and the source pid belongs to the application that created it.
    @available(macOS 26.0, *)
    init(uncheckedItemWindow itemWindow: WindowInfo, sourcePID: pid_t?, applications: inout RunningApplicationLookup) {
        self.namespace = Namespace(uncheckedItemWindow: itemWindow, sourcePID: sourcePID, applications: &applications)
        self.title = itemWindow.title ?? ""
    }
}

// MARK: - MenuBarItemTag.Namespace Helper

private extension MenuBarItemTag.Namespace {
    /// Identifiers for the items whose source process is unknown, by window.
    ///
    /// Lists of menu bar items are read from more than one task at once, so
    /// the cache is protected by a lock. Mutating a plain dictionary from two
    /// threads can corrupt it and crash.
    private static let uuidCache = OSAllocatedUnfairLock(initialState: [CGWindowID: UUID]())

    /// The window titles of Icey's control items.
    private static let controlItemTitles = Set(ControlItem.Identifier.allCases.map(\.rawValue))

    /// Creates a namespace without checks.
    ///
    /// This initializer does not perform validity checks on its parameters.
    /// Only call it if you are certain the window is a valid menu bar item.
    init(uncheckedItemWindow itemWindow: WindowInfo, applications: inout RunningApplicationLookup) {
        // Most apps have a bundle ID, but we should be able to handle apps
        // that don't. We should also be able to handle daemons and helpers,
        // which are more likely not to have a bundle ID.
        //
        // Use the name of the owning process as a fallback. The non-localized
        // name seems less likely to change, so let's prefer it as a (somewhat)
        // stable identifier.
        if let app = applications.application(for: itemWindow.ownerPID) {
            self = .optional(app.bundleIdentifier ?? itemWindow.ownerName ?? app.localizedName)
        } else {
            self = .optional(itemWindow.ownerName)
        }
    }

    /// Creates a namespace without checks.
    ///
    /// This initializer does not perform validity checks on its parameters.
    /// Only call it if you are certain the window is a valid menu bar item
    /// and the source pid belongs to the application that created it.
    @available(macOS 26.0, *)
    init(uncheckedItemWindow itemWindow: WindowInfo, sourcePID: pid_t?, applications: inout RunningApplicationLookup) {
        // Most apps have a bundle ID, but we should be able to handle apps
        // that don't. We should also be able to handle daemons and helpers,
        // which are more likely not to have a bundle ID.
        if let sourcePID, let app = applications.application(for: sourcePID) {
            self = .optional(app.bundleIdentifier ?? app.localizedName)
        } else if let title = itemWindow.title, Self.controlItemTitles.contains(title) {
            // Control Center owns every item window on macOS 26, Icey's own
            // control items included, and their source process is looked up
            // like any other app's. When that failed, the control items got
            // an identifier of their own, the hidden section's divider was
            // not recognized, and the item cache was cleared on every update.
            // Their window titles are still Icey's.
            self = .ice
        } else {
            let uuid = Self.uuidCache.withLock { cache in
                if let uuid = cache[itemWindow.windowID] {
                    return uuid
                }
                let uuid = UUID()
                cache[itemWindow.windowID] = uuid
                return uuid
            }
            self = .uuid(uuid)
        }
    }
}

// MARK: - RunningApplicationLookup

/// Looks up the running application of each process once while a list of
/// menu bar items is created.
///
/// Several items often belong to the same process, and each lookup asks
/// the system. A lookup lives only while one list is created, so a process
/// identifier that is reused later is looked up again.
private struct RunningApplicationLookup {
    private var applications = [pid_t: NSRunningApplication?]()

    /// Returns the running application for the given process identifier.
    mutating func application(for pid: pid_t) -> NSRunningApplication? {
        if let application = applications[pid] {
            return application
        }
        let application = NSRunningApplication(processIdentifier: pid)
        applications.updateValue(application, forKey: pid)
        return application
    }
}
