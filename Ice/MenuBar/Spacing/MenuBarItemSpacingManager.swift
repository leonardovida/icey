//
//  MenuBarItemSpacingManager.swift
//  Ice
//

import Cocoa
import Combine
import OSLog

/// Manager for menu bar item spacing.
@MainActor
final class MenuBarItemSpacingManager {
    /// UserDefaults keys.
    private enum Key: String {
        case spacing = "NSStatusItemSpacing"
        case padding = "NSStatusItemSelectionPadding"

        /// The default value for the key.
        var defaultValue: Int {
            switch self {
            case .spacing: 16
            case .padding: 16
            }
        }
    }

    /// An error that groups multiple failed app relaunches.
    private struct GroupedRelaunchError: LocalizedError {
        let failedApps: [String]

        var errorDescription: String? {
            String(localized: "The following applications didn't quit, so they were not restarted:") + "\n" + failedApps.joined(separator: "\n")
        }

        var recoverySuggestion: String? {
            String(localized: "Quit and reopen them yourself, or log out, for the new spacing to take effect.")
        }
    }

    /// Logger for the menu bar item spacing manager.
    private let logger = Logger(category: "MenuBarItemSpacingManager")

    /// How long to wait for an app to quit when asked.
    ///
    /// Long enough for the app to finish quitting on its own, or for the user
    /// to answer an app that asks to save its documents.
    private let quitTimeout = 10

    /// Bundle identifiers of macOS's own menu bar agents.
    ///
    /// They hold no documents and macOS starts them again right away, so they
    /// may be force terminated if they ignore a request to quit. Other apps are
    /// never force terminated: an app that keeps running, for example because
    /// it is asking to save a document, is left alone and reported instead
    /// (jordanbaird/Ice#963 noted that force terminating lost unsaved work).
    private let systemAgentBundleIdentifiers: Set<String> = [
        "com.apple.controlcenter",
        "com.apple.Spotlight",
        "com.apple.systemuiserver",
        "com.apple.TextInputMenuAgent",
    ]

    /// The offset to apply to the default spacing and padding.
    /// Does not take effect until ``applyOffset()`` is called.
    var offset = 0

    /// Runs a command with the given arguments.
    private func runCommand(_ command: String, with arguments: [String]) async throws {
        let process = Process()

        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = CollectionOfOne(command) + arguments

        let task = Task.detached {
            try process.run()
            process.waitUntilExit()
        }

        return try await task.value
    }

    /// Removes the value for the specified key.
    private func removeValue(forKey key: Key) async throws {
        try await runCommand("defaults", with: ["-currentHost", "delete", "-globalDomain", key.rawValue])
    }

    /// Sets the value for the specified key to the key's default value plus the given offset.
    private func setOffset(_ offset: Int, forKey key: Key) async throws {
        try await runCommand("defaults", with: ["-currentHost", "write", "-globalDomain", key.rawValue, "-int", String(key.defaultValue + offset)])
    }

    /// Returns a Boolean value that indicates whether the given app is one of
    /// macOS's own menu bar agents.
    ///
    /// A bundle identifier alone proves nothing, as any app can declare one,
    /// so the app must also live on the read-only system volume.
    private func isSystemAgent(_ app: NSRunningApplication) -> Bool {
        guard
            let bundleIdentifier = app.bundleIdentifier,
            systemAgentBundleIdentifiers.contains(bundleIdentifier),
            let path = app.bundleURL?.resolvingSymlinksInPath().path
        else {
            return false
        }
        return path.hasPrefix("/System/")
    }

    /// Asynchronously signals the given app to quit.
    private func signalAppToQuit(_ app: NSRunningApplication) async throws {
        if app.isTerminated {
            logger.debug("Application \"\(app.logString, privacy: .public)\" is already terminated")
            return
        } else {
            logger.debug("Signaling application \"\(app.logString, privacy: .public)\" to quit")
        }

        app.terminate()

        // The continuation must resume exactly once: when the app is seen to
        // terminate, or after the timeout, when the caller sees that the app
        // is still running and doesn't restart it.
        let didResume = OSAllocatedUnfairLock(initialState: false)
        var cancellable: AnyCancellable?
        return await withCheckedContinuation { continuation in
            let resume = {
                let isFirst = didResume.withLock { didResume in
                    defer { didResume = true }
                    return !didResume
                }
                if isFirst {
                    cancellable?.cancel()
                    continuation.resume()
                }
            }

            let timeoutTask = Task {
                try await Task.sleep(for: .seconds(quitTimeout))
                if !app.isTerminated {
                    if isSystemAgent(app) {
                        logger.debug(
                            """
                            System agent \"\(app.logString, privacy: .public)\" did not quit within \
                            \(self.quitTimeout, privacy: .public) seconds, force terminating it
                            """
                        )
                        app.forceTerminate()
                        try await Task.sleep(for: .seconds(1))
                    } else {
                        logger.debug(
                            """
                            Application \"\(app.logString, privacy: .public)\" did not quit within \
                            \(self.quitTimeout, privacy: .public) seconds, leaving it running
                            """
                        )
                    }
                }
                resume()
            }

            cancellable = app.publisher(for: \.isTerminated).sink { [weak self] isTerminated in
                guard isTerminated else {
                    return
                }
                timeoutTask.cancel()
                self?.logger.debug("Application \"\(app.logString, privacy: .public)\" terminated successfully")
                resume()
            }
            // The publisher sends the current value as soon as it is
            // subscribed to, before `cancellable` is set.
            if didResume.withLock({ $0 }) {
                cancellable?.cancel()
            }
        }
    }

    /// Asynchronously launches the app at the given URL, unless it is
    /// already running.
    ///
    /// - Parameter replacedPID: The process identifier of the instance that
    ///   was just quit. The list of running apps can still contain it, and
    ///   counting it as running skipped the relaunch. A new instance, such
    ///   as one started again by launchd, still counts.
    private nonisolated func launchApp(at applicationURL: URL, bundleIdentifier: String, replacedPID: pid_t) async throws {
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleIdentifier && $0.processIdentifier != replacedPID
        }) {
            logger.debug("Application \"\(app.logString, privacy: .public)\" is already open, so skipping launch")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = false
        configuration.promptsUserIfNeeded = false
        try await NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration)
    }

    /// Asynchronously relaunches the given app.
    private func relaunchApp(_ app: NSRunningApplication) async throws {
        struct RelaunchError: Error { }
        guard
            let url = app.bundleURL,
            let bundleIdentifier = app.bundleIdentifier
        else {
            throw RelaunchError()
        }
        let pid = app.processIdentifier
        try await signalAppToQuit(app)
        if app.isTerminated {
            try await launchApp(at: url, bundleIdentifier: bundleIdentifier, replacedPID: pid)
        } else {
            throw RelaunchError()
        }
    }

    /// Applies the current ``offset``.
    ///
    /// - Note: Calling this restarts all apps with a menu bar item.
    func applyOffset() async throws {
        if offset == 0 {
            try await removeValue(forKey: .spacing)
            try await removeValue(forKey: .padding)
        } else {
            try await setOffset(offset, forKey: .spacing)
            try await setOffset(offset, forKey: .padding)
        }

        try? await Task.sleep(for: .milliseconds(100))

        let items = await MenuBarItem.getMenuBarItems(option: .activeSpace)
        let pids = Set(items.map { $0.sourcePID ?? $0.ownerPID })

        var failedApps = [String]()

        await withTaskGroup(of: Void.self) { group in
            for pid in pids {
                guard
                    let app = NSRunningApplication(processIdentifier: pid),
                    app.bundleIdentifier != "com.apple.controlcenter", // ControlCenter handles its own relaunch, so skip it.
                    app != .current
                else {
                    continue
                }
                group.addTask { @MainActor in
                    do {
                        try await self.relaunchApp(app)
                    } catch {
                        guard let name = app.localizedName else {
                            return
                        }
                        if app.bundleIdentifier == "com.apple.Spotlight" {
                            // Spotlight automatically relaunches, so only consider it a failure if it never quit.
                            if
                                let latestSpotlightInstance = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Spotlight").first,
                                latestSpotlightInstance.processIdentifier == app.processIdentifier
                            {
                                failedApps.append(name)
                            }
                        } else {
                            failedApps.append(name)
                        }
                    }
                }
            }
        }

        try? await Task.sleep(for: .milliseconds(100))

        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter").first {
            do {
                try await signalAppToQuit(app)
            } catch {
                if let name = app.localizedName {
                    failedApps.append(name)
                }
            }
        }

        if !failedApps.isEmpty {
            throw GroupedRelaunchError(failedApps: failedApps)
        }
    }
}

private extension NSRunningApplication {
    /// A string to use for logging purposes.
    var logString: String {
        localizedName ?? bundleIdentifier ?? "<NIL>"
    }
}
