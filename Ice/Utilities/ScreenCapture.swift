//
//  ScreenCapture.swift
//  Ice
//

import CoreGraphics
import os
import ScreenCaptureKit

/// A namespace for screen capture operations.
enum ScreenCapture {

    // MARK: Permissions

    /// Returns a Boolean value that indicates whether the app has screen
    /// capture permissions.
    static func checkPermissions() -> Bool {
        for windowID in Bridging.getMenuBarWindowList(option: [.itemsOnly, .activeSpace]) {
            guard
                let window = WindowInfo(windowID: windowID),
                window.owningApplication != .current // Skip windows we own.
            else {
                continue
            }
            return window.title != nil
        }
        // CGPreflightScreenCaptureAccess() only returns an initial value,
        // but we can use it as a fallback.
        return CGPreflightScreenCaptureAccess()
    }

    /// Returns a Boolean value that indicates whether the app has screen
    /// capture permissions.
    ///
    /// This function caches a positive result and returns it on subsequent
    /// calls. A negative result is not cached, so that a permission granted
    /// while the app is running is picked up. Pass `true` to the `reset`
    /// parameter to replace the cached result with a newly computed value.
    static func cachedCheckPermissions(reset: Bool = false) -> Bool {
        enum Context {
            static var cachedResult: Bool?
        }
        if !reset, let result = Context.cachedResult {
            return result
        }
        let result = checkPermissions()
        Context.cachedResult = result ? true : nil
        return result
    }

    /// Requests screen capture permissions.
    static func requestPermissions() {
        if #available(macOS 15.0, *) {
            // CGRequestScreenCaptureAccess() is broken on macOS 15. We can
            // try accessing SCShareableContent to trigger a request if the
            // user doesn't have permissions.
            // TODO: Find out if we still need this as of macOS 26.
            SCShareableContent.getWithCompletionHandler { _, _ in }
        } else {
            CGRequestScreenCaptureAccess()
        }
    }

    // MARK: Capture Window(s)

    /// Captures a composite image of an array of windows.
    ///
    /// The windows are composited from front to back, according to the order
    /// of the `windowIDs` parameter.
    ///
    /// - Parameters:
    ///   - windowIDs: The identifiers of the windows to capture.
    ///   - screenBounds: The bounds to capture, specified in screen coordinates.
    ///     Pass `nil` to capture the minimum rectangle that encloses the windows.
    ///   - option: Options that specify which parts of the windows are captured.
    static func captureWindows(with windowIDs: [CGWindowID], screenBounds: CGRect? = nil, option: CGWindowImageOption = []) -> CGImage? {
        guard let array = Bridging.createCGWindowArray(with: windowIDs) else {
            return nil
        }
        let bounds = screenBounds ?? .null
        // ScreenCaptureKit doesn't support capturing images of offscreen menu bar
        // items, so we unfortunately have to use the deprecated CGWindowList API.
        return CGImage(windowListFromArrayScreenBounds: bounds, windowArray: array, imageOption: option)
    }

    /// Captures an image of a window.
    ///
    /// - Parameters:
    ///   - windowID: The identifier of the window to capture.
    ///   - screenBounds: The bounds to capture, specified in screen coordinates.
    ///     Pass `nil` to capture the minimum rectangle that encloses the window.
    ///   - option: Options that specify which parts of the window are captured.
    static func captureWindow(with windowID: CGWindowID, screenBounds: CGRect? = nil, option: CGWindowImageOption = []) -> CGImage? {
        captureWindows(with: [windowID], screenBounds: screenBounds, option: option)
    }

    // MARK: Menu Bar Color

    /// The queue the menu bar color captures run on.
    ///
    /// A capture blocks its thread for about 10 milliseconds, waiting on the
    /// window server, for about 1 millisecond of work. It runs here rather than
    /// on the main thread. Like the item captures in ``MenuBarItemImageCache``,
    /// it stays off the Swift concurrency pool, and the queue is serial, so a
    /// capture that never returns costs one thread. It is a queue of its own,
    /// so that the Ice Bar's color capture does not wait behind its item capture.
    private static let menuBarColorQueue = DispatchQueue(
        label: "com.jordanbaird.Ice.MenuBarColorCapture",
        qos: .userInitiated
    )

    /// Captures a one pixel high strip of the menu bar and the wallpaper
    /// behind it, across the given display.
    ///
    /// The menu bar's average color is read from this image. This blocks
    /// the calling thread.
    static func captureMenuBarStrip(for displayID: CGDirectDisplayID) -> CGImage? {
        let windows = WindowInfo.createWindows(option: .onScreen)

        guard
            let menuBarWindow = WindowInfo.menuBarWindow(from: windows, for: displayID),
            let wallpaperWindow = WindowInfo.wallpaperWindow(from: windows, for: displayID)
        else {
            return nil
        }

        return captureWindows(
            with: [menuBarWindow.windowID, wallpaperWindow.windowID],
            screenBounds: withMutableCopy(of: wallpaperWindow.bounds) { $0.size.height = 1 },
            option: .nominalResolution
        )
    }

    /// The state of the menu bar color captures.
    private struct MenuBarColorCaptures {
        /// The callers waiting for a strip capture that has not started,
        /// by display.
        var waitingForStrip = [CGDirectDisplayID: [CheckedContinuation<CGImage?, Never>]]()

        /// The callers waiting for an average color capture that has not
        /// started, by display.
        var waitingForAverageColor = [CGDirectDisplayID: [CheckedContinuation<CGColor?, Never>]]()

        /// When the capture that is running started.
        var runningSince: ContinuousClock.Instant?
    }

    /// The state of the menu bar color captures.
    private static let menuBarColorCaptures = OSAllocatedUnfairLock(initialState: MenuBarColorCaptures())

    /// How long a capture may run before the queue counts as blocked.
    private static let menuBarColorCaptureLimit: Duration = .seconds(2)

    /// Runs the given capture on ``menuBarColorQueue``, and returns its result.
    ///
    /// Requests for the same kind and display that arrive before a capture
    /// starts share it, so at most one waits for each. While a capture has
    /// run for longer than ``menuBarColorCaptureLimit``, which happens only
    /// when the window server doesn't answer, new requests return `nil` at
    /// once, as a failed capture does, so they can't pile up behind it.
    private static func menuBarColorCapture<Value: Sendable>(
        for displayID: CGDirectDisplayID,
        waiting: WritableKeyPath<MenuBarColorCaptures, [CGDirectDisplayID: [CheckedContinuation<Value?, Never>]]> & Sendable,
        capture: @escaping @Sendable () -> Value?
    ) async -> Value? {
        await withCheckedContinuation { continuation in
            let shouldStart: Bool? = menuBarColorCaptures.withLock { state in
                if let runningSince = state.runningSince, runningSince.duration(to: .now) > menuBarColorCaptureLimit {
                    return nil
                }
                if state[keyPath: waiting][displayID] != nil {
                    state[keyPath: waiting][displayID]?.append(continuation)
                    return false
                }
                state[keyPath: waiting][displayID] = [continuation]
                return true
            }
            guard let shouldStart else {
                continuation.resume(returning: nil)
                return
            }
            guard shouldStart else {
                return
            }
            menuBarColorQueue.async {
                let callers = menuBarColorCaptures.withLock { state in
                    state.runningSince = .now
                    return state[keyPath: waiting].removeValue(forKey: displayID) ?? []
                }
                let value = capture()
                menuBarColorCaptures.withLock { state in
                    state.runningSince = nil
                }
                for caller in callers {
                    caller.resume(returning: value)
                }
            }
        }
    }

    /// Captures the strip that ``captureMenuBarStrip(for:)`` captures, off the
    /// main thread.
    ///
    /// The image's pixels are read before it is returned. The first read waits
    /// for the window server, so a caller that crops or averages the image
    /// afterwards does not wait.
    static func menuBarStrip(for displayID: CGDirectDisplayID) async -> CGImage? {
        await menuBarColorCapture(for: displayID, waiting: \.waitingForStrip) {
            let image = captureMenuBarStrip(for: displayID)
            _ = image?.dataProvider?.data
            return image
        }
    }

    /// Returns the average color, ignoring alpha, of the strip that
    /// ``captureMenuBarStrip(for:)`` captures, computed off the main thread.
    static func menuBarAverageColor(for displayID: CGDirectDisplayID) async -> CGColor? {
        await menuBarColorCapture(for: displayID, waiting: \.waitingForAverageColor) {
            captureMenuBarStrip(for: displayID)?.averageColor(option: .ignoreAlpha)
        }
    }
}
