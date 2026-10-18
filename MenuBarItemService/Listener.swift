//
//  Listener.swift
//  MenuBarItemService
//

import OSLog
import XPC

/// A wrapper around an XPC listener object.
final class Listener {
    /// The shared listener.
    static let shared = Listener()

    /// The service name.
    private let name = MenuBarItemService.name

    /// The underlying XPC listener object.
    private var listener: XPCListener?

    /// Creates the shared listener.
    private init() { }

    deinit {
        cancel()
    }

    /// Handles a received message.
    private func handleMessage(_ message: XPCReceivedMessage) -> MenuBarItemService.Response? {
        do {
            let request = try message.decode(as: MenuBarItemService.Request.self)
            switch request {
            case .start:
                Logger.default.debug("Listener received start request")
                return .start
            case .sourcePID(let window):
                let pid = SourcePIDCache.shared.pid(for: window)
                return .sourcePID(pid)
            case .sourcePIDs(let windows):
                let pids = SourcePIDCache.shared.pids(for: windows)
                return .sourcePIDs(pids)
            }
        } catch {
            Logger.default.error("Listener failed to handle message with error \(error)")
            return nil
        }
    }

    /// The signing identifier of the app that contains the service.
    private var appSigningIdentifier: String {
        // The service is embedded at Ice.app/Contents/XPCServices/MenuBarItemService.xpc,
        // and the app's signing identifier is its bundle identifier.
        let appURL = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return Bundle(url: appURL)?.bundleIdentifier ?? "com.jordanbaird.Ice"
    }

    /// Activates the listener without checking if it is already active,
    /// with the requirement that session peers must be signed by the same
    /// team as the service process or, for builds without a team, with
    /// the app's signing identifier.
    @available(macOS 26.0, *)
    private func uncheckedActivateWithPeerRequirement() throws {
        let requirement = MenuBarItemService.peerRequirement(signingIdentifier: appSigningIdentifier)
        listener = try XPCListener(service: name, requirement: requirement) { [weak self] request in
            request.accept { message in
                self?.handleMessage(message)
            }
        }
    }

    /// Activates the listener without checking if it is already active.
    private func uncheckedActivate() throws {
        listener = try XPCListener(service: name) { [weak self] request in
            request.accept { message in
                self?.handleMessage(message)
            }
        }
    }

    /// Activates the listener.
    func activate() {
        guard listener == nil else {
            Logger.default.notice("Listener is already active")
            return
        }

        Logger.default.debug("Activating listener")

        do {
            if #available(macOS 26.0, *) {
                try uncheckedActivateWithPeerRequirement()
            } else {
                try uncheckedActivate()
            }
        } catch {
            Logger.default.error("Failed to activate listener with error \(error)")
        }
    }

    /// Cancels the listener.
    func cancel() {
        Logger.default.debug("Canceling listener")
        listener.take()?.cancel()
    }
}
