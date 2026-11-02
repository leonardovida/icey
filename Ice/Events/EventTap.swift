//
//  EventTap.swift
//  Ice
//

import Cocoa
import OSLog

/// An object that receives events from a defined point in
/// the event stream.
final class EventTap {
    /// Constants that specify the possible insertion points
    /// for event taps.
    enum Location {
        /// The point where HID system events enter the window
        /// server.
        case hidEventTap

        /// The point where HID system and remote control events
        /// enter a login session.
        case sessionEventTap

        /// The point for session events that have been annotated
        /// to flow to an application.
        case annotatedSessionEventTap

        /// The point where events are delivered to the process
        /// with the specified identifier.
        case pid(pid_t)

        /// A string to use for logging purposes.
        var logString: String {
            switch self {
            case .hidEventTap: "HID event tap"
            case .sessionEventTap: "session event tap"
            case .annotatedSessionEventTap: "annotated session event tap"
            case .pid(let pid): "PID \(pid)"
            }
        }
    }

    /// Shared logger for event taps.
    private static let logger = Logger(category: "EventTap")

    /// The context passed to the shared callback, which refers to the tap
    /// weakly.
    ///
    /// The callback runs on the main run loop, but a tap can be released on
    /// another thread, as the taps for moving items are. The callback used to
    /// rebuild the tap itself from an unretained pointer, so a tap released
    /// while its callback was starting was used after it was freed. The
    /// context outlives the tap, and is released on the main queue after the
    /// tap's port is invalidated, once no callback can be running.
    private final class CallbackContext {
        weak var tap: EventTap?
    }

    /// Shared callback for all event taps.
    private static let sharedCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else {
            return Unmanaged.passUnretained(event)
        }
        let context: CallbackContext = Unmanaged.fromOpaque(refcon).takeUnretainedValue()
        guard let tap = context.tap else {
            return Unmanaged.passUnretained(event)
        }
        return withExtendedLifetime(tap) { tap in
            if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout {
                tap.enable()
                return nil
            }
            guard tap.isEnabled else {
                return Unmanaged.passUnretained(event)
            }
            return tap.callback(tap, event).map { eventFromCallback in
                Unmanaged.passUnretained(eventFromCallback)
            }
        }
    }

    private var machPort: CFMachPort?
    private var source: CFRunLoopSource?
    private let context: Unmanaged<CallbackContext>
    private let runLoop: CFRunLoop
    private let callback: (EventTap, CGEvent) -> CGEvent?

    /// A string label that identifies the tap.
    let label: String

    /// A Boolean value that indicates whether the tap is actively
    /// listening for events.
    var isEnabled: Bool {
        guard let machPort else { return false }
        return CGEvent.tapIsEnabled(tap: machPort)
    }

    /// A Boolean value that indicates whether the tap is valid and
    /// able to receive events.
    var isValid: Bool {
        guard let machPort else { return false }
        return CFMachPortIsValid(machPort)
    }

    /// Creates a new event tap for the specified event types.
    ///
    /// If the tap is an active filter, the callback can return
    /// one of the following:
    ///
    ///   * The (possibly modified) received event to pass back to
    ///     the event stream.
    ///   * A new event to pass to the event stream in place of the
    ///     received event.
    ///   * `nil` to remove the received event from the event stream.
    ///
    /// If the tap is a passive listener, the callback's return value
    /// does not affect the event stream.
    ///
    /// - Parameters:
    ///   - label: A string label that identifies the tap in logging
    ///     and debugging contexts.
    ///   - types: The event types monitored by the tap.
    ///   - location: The point in the event stream to insert the tap.
    ///   - placement: The tap's placement, relative to existing taps
    ///     at `location`.
    ///   - option: An option that specifies whether the tap is an
    ///     active filter or a passive listener.
    ///   - callback: A closure the tap calls to handle received events.
    init(
        label: String = #function,
        types: [CGEventType],
        location: Location,
        placement: CGEventTapPlacement,
        option: CGEventTapOptions,
        callback: @escaping (_ tap: EventTap, _ event: CGEvent) -> CGEvent?
    ) {
        self.label = label
        self.callback = callback
        self.runLoop = CFRunLoopGetMain()
        self.context = Unmanaged.passRetained(CallbackContext())
        context.takeUnretainedValue().tap = self

        guard
            let machPort = EventTap.createMachPort(
                mask: types.reduce(0) { $0 | (1 << $1.rawValue) },
                location: location,
                place: placement,
                options: option,
                userInfo: context.toOpaque()
            ),
            let source = CFMachPortCreateRunLoopSource(nil, machPort, 0)
        else {
            EventTap.logger.error(#"Error creating event tap "\#(label, privacy: .public)""#)
            return
        }

        self.machPort = machPort
        self.source = source
    }

    /// Creates a new event tap for the specified event type.
    ///
    /// If the tap is an active filter, the callback can return
    /// one of the following:
    ///
    ///   * The (possibly modified) received event to pass back to
    ///     the event stream.
    ///   * A new event to pass to the event stream in place of the
    ///     received event.
    ///   * `nil` to remove the received event from the event stream.
    ///
    /// If the tap is a passive listener, the callback's return value
    /// does not affect the event stream.
    ///
    /// - Parameters:
    ///   - label: A string label that identifies the tap in logging
    ///     and debugging contexts.
    ///   - type: The event type monitored by the tap.
    ///   - location: The point in the event stream to insert the tap.
    ///   - placement: The tap's placement, relative to existing taps
    ///     at `location`.
    ///   - option: An option that specifies whether the tap is an
    ///     active filter or a passive listener.
    ///   - callback: A closure the tap calls to handle received events.
    convenience init(
        label: String = #function,
        type: CGEventType,
        location: Location,
        placement: CGEventTapPlacement,
        option: CGEventTapOptions,
        callback: @escaping (_ tap: EventTap, _ event: CGEvent) -> CGEvent?
    ) {
        self.init(
            label: label,
            types: [type],
            location: location,
            placement: placement,
            option: option,
            callback: callback
        )
    }

    deinit {
        if let source {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
        }
        if let machPort {
            CGEvent.tapEnable(tap: machPort, enable: false)
            CFMachPortInvalidate(machPort)
        }
        // A callback that started before the port was invalidated runs on the
        // main queue, so it has returned by the time this block runs.
        let context = context
        DispatchQueue.main.async {
            context.release()
        }
    }

    /// Creates an event tap mach port.
    private static func createMachPort(
        mask: CGEventMask,
        location: Location,
        place: CGEventTapPlacement,
        options: CGEventTapOptions,
        userInfo: UnsafeMutableRawPointer
    ) -> CFMachPort? {
        func createMachPort(at tapLocation: CGEventTapLocation) -> CFMachPort? {
            CGEvent.tapCreate(
                tap: tapLocation,
                place: place,
                options: options,
                eventsOfInterest: mask,
                callback: sharedCallback,
                userInfo: userInfo
            )
        }

        func createMachPort(for pid: pid_t) -> CFMachPort? {
            CGEvent.tapCreateForPid(
                pid: pid,
                place: place,
                options: options,
                eventsOfInterest: mask,
                callback: sharedCallback,
                userInfo: userInfo
            )
        }

        switch location {
        case .hidEventTap:
            return createMachPort(at: .cghidEventTap)
        case .sessionEventTap:
            return createMachPort(at: .cgSessionEventTap)
        case .annotatedSessionEventTap:
            return createMachPort(at: .cgAnnotatedSessionEventTap)
        case .pid(let pid):
            return createMachPort(for: pid)
        }
    }

    /// Enables the tap.
    func enable() {
        guard let source, let machPort else { return }
        CGEvent.tapEnable(tap: machPort, enable: true)
        CFRunLoopAddSource(runLoop, source, .commonModes)
    }

    /// Disables the tap.
    func disable() {
        guard let source, let machPort else { return }
        CFRunLoopRemoveSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: machPort, enable: false)
    }
}
