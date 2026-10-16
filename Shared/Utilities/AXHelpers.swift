//
//  AXHelpers.swift
//  Shared
//

import AXSwift
import Cocoa

enum AXHelpers {
    private static let queue = DispatchQueue.targetingGlobal(
        label: "AXHelpers.queue",
        qos: .userInteractive,
        attributes: .concurrent
    )

    /// Sets how long, in seconds, any Accessibility message sent by this process
    /// waits for the application it is sent to, unless a call sets its own.
    ///
    /// The system default is about six seconds per message. The calls here run
    /// synchronously, many of them from the main thread while the pointer moves
    /// over the menu bar, and they ask the application that owns the menu bar. An
    /// application hung in a popup menu then held the main thread for six seconds
    /// at a time, again on the next pointer event, so the sections could not be
    /// shown or hidden until that application was killed.
    static func setGlobalMessagingTimeout(_ seconds: Float) {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), seconds)
    }

    @discardableResult
    static func isProcessTrusted(prompt: Bool = false) -> Bool {
        queue.sync { checkIsProcessTrusted(prompt: prompt) }
    }

    static func element(at point: CGPoint) -> UIElement? {
        queue.sync { try? systemWideElement.elementAtPosition(Float(point.x), Float(point.y)) }
    }

    static func application(for runningApp: NSRunningApplication) -> Application? {
        queue.sync { Application(runningApp) }
    }

    /// Returns the extras menu bar of the given app, or `nil` if the app
    /// answered that it has none.
    ///
    /// Throws if the app could not answer, for example because it did not
    /// respond in time.
    static func extrasMenuBar(for app: Application) throws -> UIElement? {
        try queue.sync { try app.attribute(.extrasMenuBar) }
    }

    static func children(for element: UIElement) -> [UIElement] {
        queue.sync { try? element.arrayAttribute(.children) } ?? []
    }

    static func isEnabled(_ element: UIElement) -> Bool {
        queue.sync { try? element.attribute(.enabled) } ?? false
    }

    static func frame(for element: UIElement) -> CGRect? {
        queue.sync { try? element.attribute(.frame) }
    }

    static func role(for element: UIElement) -> Role? {
        queue.sync { try? element.role() }
    }

    /// Returns the menu bar that holds the application menus, found at the
    /// given point before macOS 27.
    ///
    /// On macOS 27 the element at a display's origin is MenuBarAgent's window,
    /// so the menu bar comes from the application that owns it. Ice's own menus
    /// are skipped there: asking our own process from the main thread would wait
    /// for the main thread itself.
    static func applicationMenuBar(at point: CGPoint) -> UIElement? {
        if #available(macOS 27.0, *) {
            guard
                let owner = NSWorkspace.shared.menuBarOwningApplication,
                owner.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                let app = application(for: owner)
            else {
                return nil
            }
            return queue.sync { try? app.attribute(.menuBar) }
        }
        guard let element = element(at: point), role(for: element) == .menuBar else {
            return nil
        }
        return element
    }
}
