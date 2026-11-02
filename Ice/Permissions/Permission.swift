//
//  Permission.swift
//  Ice
//

import Combine
import Cocoa

// MARK: - Permission

/// An object that encapsulates the behavior of checking for and requesting
/// a specific permission for the app.
@MainActor
class Permission: ObservableObject, Identifiable {
    /// A Boolean value that indicates whether the app has this permission.
    @Published private(set) var hasPermission = false

    /// The title of the permission.
    let title: String

    /// Descriptive details for the permission.
    let details: [String]

    /// A Boolean value that indicates if the app can work without this permission.
    let isRequired: Bool

    /// The URL of the settings pane to open.
    private let settingsURL: URL?

    /// The URL of the permission's list in System Settings > Privacy & Security.
    private let privacyListURL: URL?

    /// The name of the permission's service, as `tccutil` knows it.
    private let tccService: String

    /// The function that checks permissions.
    private let check: () -> Bool

    /// The function that requests permissions.
    private let request: () -> Void

    /// A Boolean value that indicates whether to stop the permission check
    /// once the permission is granted.
    private var stopsCheckWhenGranted = false

    /// Observer that runs on a timer to check permissions.
    private var timerCancellable: AnyCancellable?

    /// Observer that observes the ``hasPermission`` property.
    private var hasPermissionCancellable: AnyCancellable?

    /// The callers waiting for the app to be granted this permission.
    private var permissionWaiters = [CheckedContinuation<Void, Never>]()

    /// Creates a permission.
    ///
    /// - Parameters:
    ///   - title: The title of the permission.
    ///   - details: Descriptive details for the permission.
    ///   - isRequired: A Boolean value that indicates if the app can work without this permission.
    ///   - settingsURL: The URL of the settings pane to open.
    ///   - privacyListURL: The URL of the permission's list in System Settings.
    ///   - tccService: The name of the permission's service, as `tccutil` knows it.
    ///   - check: A function that checks permissions.
    ///   - request: A function that requests permissions.
    init(
        title: String,
        details: [String],
        isRequired: Bool,
        settingsURL: URL?,
        privacyListURL: URL?,
        tccService: String,
        check: @escaping () -> Bool,
        request: @escaping () -> Void
    ) {
        self.title = title
        self.details = details
        self.isRequired = isRequired
        self.settingsURL = settingsURL
        self.privacyListURL = privacyListURL
        self.tccService = tccService
        self.check = check
        self.request = request
        self.hasPermission = check()
        configureCancellables()
    }

    /// Sets up the internal observers for the permission.
    private func configureCancellables() {
        timerCancellable = Timer.publish(every: 1, tolerance: 0.1, on: .main, in: .default)
            .autoconnect()
            .merge(with: Just(.now))
            .sink { [weak self] _ in
                guard let self else {
                    return
                }
                // Assigning the same value every second would invalidate every
                // view that observes the app state, for as long as a permission
                // is missing.
                let hasPermission = check()
                if self.hasPermission != hasPermission {
                    self.hasPermission = hasPermission
                }
                if hasPermission, stopsCheckWhenGranted {
                    timerCancellable = nil
                }
            }
    }

    /// Performs the request and opens the System Settings app to the appropriate pane.
    func performRequest() {
        request()
        if let settingsURL {
            NSWorkspace.shared.open(settingsURL)
        }
    }

    /// Opens the permission's list in System Settings.
    ///
    /// The request alone does not always get there. When the list already
    /// has an entry for the app, such as one left by an earlier copy with
    /// a different signature, macOS may not prompt at all, and the entry
    /// that no longer applies can only be removed from the list.
    func openPrivacyList() {
        if let privacyListURL {
            NSWorkspace.shared.open(privacyListURL)
        }
    }

    /// Removes the app's entry for this permission in System Settings, then
    /// asks for the permission again, and returns whether the entry was removed.
    ///
    /// macOS ties the permission to the app's signature. An entry left by an
    /// earlier copy of the app, such as Ice or an ad hoc signed build, stays
    /// enabled in System Settings but no longer applies, and macOS does not
    /// ask again while it is there (jordanbaird/Ice#1004, #834). Users had to
    /// find the entry and remove it themselves.
    func resetAndRequest() async -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            return false
        }
        let service = tccService
        let isReset = await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = ["reset", service, bundleIdentifier]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return false
            }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }.value
        if isReset {
            performRequest()
        }
        return isReset
    }

    /// Asynchronously waits for the app to be granted this permission.
    func waitForPermission() async {
        configureCancellables()
        guard !hasPermission else {
            return
        }
        // Every caller waits on the same observer. A second call, such as a
        // second click on a button that asks for the permission, replaced the
        // observer, and the first caller waited forever.
        await withCheckedContinuation { continuation in
            permissionWaiters.append(continuation)
            guard hasPermissionCancellable == nil else {
                return
            }
            hasPermissionCancellable = $hasPermission.sink { [weak self] hasPermission in
                if hasPermission {
                    self?.resumePermissionWaiters()
                }
            }
        }
    }

    /// Resumes everything waiting for the permission, and stops observing it.
    private func resumePermissionWaiters() {
        hasPermissionCancellable?.cancel()
        hasPermissionCancellable = nil
        let waiters = permissionWaiters
        permissionWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Stops running the permission check.
    func stopCheck() {
        timerCancellable?.cancel()
        timerCancellable = nil
        resumePermissionWaiters()
    }

    /// Stops running the permission check once the permission is granted.
    func stopCheckWhenGranted() {
        stopsCheckWhenGranted = true
        if hasPermission {
            stopCheck()
        }
    }
}

// MARK: - AccessibilityPermission

final class AccessibilityPermission: Permission {
    init() {
        super.init(
            title: String(localized: "Accessibility"),
            details: [
                String(localized: "Get real-time information about the menu bar."),
                String(localized: "Arrange menu bar items."),
            ],
            isRequired: true,
            settingsURL: nil,
            privacyListURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"),
            tccService: "Accessibility",
            check: {
                AXHelpers.isProcessTrusted()
            },
            request: {
                AXHelpers.isProcessTrusted(prompt: true)
            }
        )
    }
}

// MARK: - ScreenRecordingPermission

final class ScreenRecordingPermission: Permission {
    init() {
        super.init(
            title: String(localized: "Screen Recording"),
            details: [
                String(localized: "Change the menu bar's appearance."),
                String(localized: "Display images of individual menu bar items."),
            ],
            isRequired: false,
            settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"),
            privacyListURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"),
            tccService: "ScreenCapture",
            check: {
                ScreenCapture.checkPermissions()
            },
            request: {
                ScreenCapture.requestPermissions()
            }
        )
    }
}
