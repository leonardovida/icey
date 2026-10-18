//
//  UsageStatistics.swift
//  Ice
//

import Combine
import Foundation
import LaunchAtLogin
import OSLog

/// Manager for the anonymous usage statistics.
///
/// While ``isEnabled`` is on, Icey sends one ``UsageReport`` a day at most:
/// a little after launch if none was sent on the current UTC day, then from
/// an `NSBackgroundActivityScheduler` that lets macOS pick an energy-efficient
/// time about once a day. Only the UTC day of the last report is stored, so
/// nothing links one report to the next. A failed report is not retried
/// before the next scheduled run.
///
/// Debug builds log the report instead of sending it, unless they are
/// launched with `-IceySendStatistics` or `ICEY_SEND_STATISTICS=1`.
@MainActor
final class UsageStatisticsManager: ObservableObject {
    /// A Boolean value that indicates whether Icey sends anonymous statistics.
    @Published var isEnabled = true

    // swiftlint:disable force_unwrapping
    /// The endpoint the reports are sent to.
    static let endpoint = URL(string: "https://icey-stats.178-105-139-229.sslip.io/v1/report")!
    // swiftlint:enable force_unwrapping

    /// How long after launch, or after the setting is turned on, the first
    /// report of the day is sent.
    private static let launchDelay: Duration = .seconds(120)

    /// How often the background activity runs, and how far macOS may move it.
    private static let interval: TimeInterval = 24 * 60 * 60
    private static let tolerance: TimeInterval = 6 * 60 * 60

    /// The timeout for sending one report.
    private static let timeout: TimeInterval = 15

    /// The shared app state.
    private(set) weak var appState: AppState?

    /// The background activity that sends the daily report.
    private var scheduler: NSBackgroundActivityScheduler?

    /// The task that sends the first report after launch.
    private var launchTask: Task<Void, Never>?

    /// The task that is sending a report.
    private var sendTask: Task<Void, Never>?

    /// A session that keeps no cookies, cache or credentials.
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = Self.timeout
        configuration.timeoutIntervalForResource = Self.timeout
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = ["User-Agent": "Icey"]
        return URLSession(configuration: configuration)
    }()

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// Logger for the manager.
    private let logger = Logger(category: "UsageStatistics")

    /// Performs the initial setup of the manager.
    func performSetup(with appState: AppState) {
        self.appState = appState
        Defaults.ifPresent(key: .sendAnonymousStatistics, assign: &isEnabled)
        configureCancellables()
    }

    /// Configures the internal observers for the manager.
    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        $isEnabled
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isEnabled in
                Defaults.set(isEnabled, forKey: .sendAnonymousStatistics)
                if isEnabled {
                    self?.start()
                } else {
                    self?.stop()
                }
            }
            .store(in: &c)

        cancellables = c
    }

    // MARK: Scheduling

    /// Schedules the daily report, and the first one after a delay.
    private func start() {
        stop()

        launchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.launchDelay, tolerance: .seconds(30))
            } catch {
                return
            }
            await self?.sendIfNeeded()
        }

        let scheduler = NSBackgroundActivityScheduler(identifier: "\(Constants.bundleIdentifier).UsageStatistics")
        scheduler.interval = Self.interval
        scheduler.tolerance = Self.tolerance
        scheduler.repeats = true
        scheduler.qualityOfService = .background
        scheduler.schedule { [weak self] completion in
            Task { @MainActor in
                await self?.sendIfNeeded()
                completion(.finished)
            }
        }
        self.scheduler = scheduler
    }

    /// Cancels the scheduled reports and any report being sent.
    private func stop() {
        scheduler?.invalidate()
        scheduler = nil
        launchTask?.cancel()
        launchTask = nil
        sendTask?.cancel()
        sendTask = nil
    }

    // MARK: Sending

    /// The current UTC day, such as `2026-10-18`.
    private static func currentDay() -> String {
        Date.now.formatted(.iso8601.year().month().day())
    }

    /// Sends today's report, unless it was already sent or is being sent.
    private func sendIfNeeded() async {
        let day = Self.currentDay()
        guard
            isEnabled,
            sendTask == nil,
            Defaults.string(forKey: .usageStatisticsLastSentDay) != day
        else {
            return
        }

        let body: Data
        do {
            body = try makeReport().encoded()
        } catch {
            logger.debug("Could not encode the anonymous statistics report: \(error, privacy: .public)")
            return
        }

        guard Self.sendsReports else {
            let json = String(bytes: body, encoding: .utf8) ?? ""
            logger.debug("Anonymous statistics report, not sent from a Debug build: \(json, privacy: .public)")
            return
        }

        let task = Task { [session, logger] in
            var request = URLRequest(
                url: Self.endpoint,
                cachePolicy: .reloadIgnoringLocalCacheData,
                timeoutInterval: Self.timeout
            )
            request.httpMethod = "POST"
            request.httpShouldHandleCookies = false
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body

            do {
                let (_, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(status) else {
                    logger.debug("The statistics service answered \(status, privacy: .public)")
                    return
                }
                // The setting may have been turned off while the report was sent.
                guard !Task.isCancelled else {
                    return
                }
                Defaults.set(day, forKey: .usageStatisticsLastSentDay)
            } catch {
                logger.debug("Could not send anonymous statistics: \(error.localizedDescription, privacy: .public)")
            }
        }
        sendTask = task
        await task.value
        if sendTask == task {
            sendTask = nil
        }
    }

    /// A Boolean value that indicates whether this build sends reports.
    private static var sendsReports: Bool {
        #if DEBUG
        let processInfo = ProcessInfo.processInfo
        return processInfo.arguments.contains("-IceySendStatistics")
            || processInfo.environment["ICEY_SEND_STATISTICS"] == "1"
        #else
        return true
        #endif
    }

    // MARK: Report

    /// Returns today's report.
    private func makeReport() -> UsageReport {
        var report = UsageReport.withSystemInformation()
        if let appState {
            report.features = features(appState: appState)
            report.settings = settings(appState: appState)
        }
        return report
    }

    /// The features that are on, by name.
    ///
    /// They show which features people use, and so which ones to make
    /// faster or keep working first. Nothing here names a menu bar item,
    /// an app, a hotkey or a display.
    private func features(appState: AppState) -> [String: Bool] {
        let general = appState.settings.general
        let advanced = appState.settings.advanced
        let appearance = appState.appearanceManager.configuration
        let partials = appearance.isDynamic
            ? [appearance.lightModeConfiguration, appearance.darkModeConfiguration]
            : [appearance.staticConfiguration]
        let hasTint = partials.contains { $0.tintKind != .noTint }
        let hasBorder = partials.contains { $0.hasBorder }
        let hasShadow = partials.contains { $0.hasShadow }
        let hasShape = appearance.shapeKind != .noShape

        var features: [String: Bool] = [
            "showIceIcon": general.showIceIcon,
            "customIceIcon": general.iceIcon.name == .custom,
            "useIceBar": general.useIceBar,
            "iceBarAnimation": general.animateIceBar,
            "showOnClick": general.showOnClick,
            "showOnHover": general.showOnHover,
            "showOnScroll": general.showOnScroll,
            "autoRehide": general.autoRehide,
            "customSpacing": general.itemSpacingOffset != 0,
            "perDisplaySettings": !appState.settings.displays.configurations.isEmpty,
            "alwaysHiddenSection": advanced.enableAlwaysHiddenSection,
            "showAllSectionsOnUserDrag": advanced.showAllSectionsOnUserDrag,
            "hideApplicationMenus": advanced.hideApplicationMenus,
            "secondaryContextMenu": advanced.enableSecondaryContextMenu,
            "showInDockWhileSettingsOpen": advanced.showInDockWhileSettingsOpen,
            "customAppearance": hasTint || hasBorder || hasShadow || hasShape,
            "menuBarTint": hasTint,
            "menuBarBorder": hasBorder,
            "menuBarShadow": hasShadow,
            "dynamicAppearance": appearance.isDynamic,
            "launchAtLogin": LaunchAtLogin.isEnabled,
            "automaticUpdates": appState.updatesManager.automaticallyChecksForUpdates,
            "automaticDownloads": appState.updatesManager.automaticallyDownloadsUpdates,
            "screenRecording": appState.permissions.screenRecording.hasPermission,
        ]
        if #available(macOS 27.0, *) {
            features["captureIndicator"] = advanced.showCaptureIndicator
        }
        return features
    }

    /// A few setting values, by name.
    ///
    /// They show which choices people make, and whether the defaults suit
    /// most of them.
    private func settings(appState: AppState) -> [String: String] {
        let general = appState.settings.general
        let advanced = appState.settings.advanced
        let appearance = appState.appearanceManager.configuration

        var settings: [String: String] = [
            "rehideStrategy": general.rehideStrategy.statisticsValue,
            "iceBarLocation": general.iceBarLocation.statisticsValue,
            "iceBarDisplays": general.iceBarDisplays.statisticsValue,
            "newItemPlacement": general.newItemPlacement.statisticsValue,
            "sectionDividerStyle": advanced.sectionDividerStyle.statisticsValue,
            "menuBarShape": appearance.shapeKind.statisticsValue,
            "configuredDisplays": String(min(appState.settings.displays.configurations.count, 16)),
        ]
        if let offset = Self.integer(general.itemSpacingOffset) {
            settings["itemSpacingOffset"] = String(offset)
        }
        if let interval = Self.integer(general.rehideInterval) {
            settings["rehideInterval"] = String(interval)
        }
        if let delay = Self.integer(advanced.showOnHoverDelay * 1000) {
            settings["showOnHoverDelayMs"] = String(delay)
        }
        return settings
    }

    /// The given value rounded to an integer, if it is a reasonable one.
    private static func integer(_ value: Double) -> Int? {
        let rounded = value.rounded()
        guard rounded.isFinite, abs(rounded) <= 1_000_000 else {
            return nil
        }
        return Int(exactly: rounded)
    }
}

// MARK: - Statistics Values

// The value each setting has in the report. They are spelled out rather than
// taken from the raw values, so renumbering a case can't change the meaning
// of earlier reports.

private extension RehideStrategy {
    var statisticsValue: String {
        switch self {
        case .smart: "smart"
        case .timed: "timed"
        case .focusedApp: "focusedApp"
        }
    }
}

private extension IceBarLocation {
    var statisticsValue: String {
        switch self {
        case .dynamic: "dynamic"
        case .mousePointer: "mousePointer"
        case .iceIcon: "iceIcon"
        }
    }
}

private extension IceBarDisplays {
    var statisticsValue: String {
        switch self {
        case .all: "all"
        case .withNotch: "withNotch"
        case .builtIn: "builtIn"
        case .narrowerThan: "narrowerThan"
        }
    }
}

private extension NewItemPlacement {
    var statisticsValue: String {
        switch self {
        case .automatic: "automatic"
        case .visible: "visible"
        case .hidden: "hidden"
        case .alwaysHidden: "alwaysHidden"
        }
    }
}

private extension SectionDividerStyle {
    var statisticsValue: String {
        switch self {
        case .noDivider: "none"
        case .chevron: "chevron"
        }
    }
}

private extension MenuBarShapeKind {
    var statisticsValue: String {
        switch self {
        case .noShape: "none"
        case .full: "full"
        case .split: "split"
        }
    }
}
