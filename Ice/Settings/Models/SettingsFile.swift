//
//  SettingsFile.swift
//  Ice
//

import Cocoa
import OSLog
import UniformTypeIdentifiers

// MARK: - SettingsFile

/// A copy of the user's settings in a file, for moving them to another Mac
/// or keeping them with other configuration files (jordanbaird/Ice#326).
///
/// The file is JSON. Settings that Icey stores as encoded data, such as the
/// hotkeys and the menu bar appearance, are written as nested JSON values, so
/// the whole file is readable text:
///
/// ```json
/// {
///   "format" : "Icey Settings",
///   "version" : 1,
///   "appVersion" : "0.11.13",
///   "settings" : { "AutoRehide" : true, "Hotkeys" : { ... }, ... }
/// }
/// ```
///
/// Only the keys in ``entries`` are written or read. Everything else Icey
/// keeps in its defaults is left out on purpose:
///
/// - Migration markers, `MacOS27LayoutSeeded` and
///   `UsageStatisticsLastSentDay`, which record what this Mac has already
///   done.
/// - `MacOS27MenuReach` and `MacOS27MenuOwner`, measurements of this Mac's
///   displays, keyed by display.
/// - `MacOS27ClickRestoreDelay` and `MacOS27IceBarWaitsForRefresh`, hidden
///   overrides for measuring.
/// - `ItemSpacingOffset`, which macOS applies to every app system-wide, and
///   which Icey only applies by relaunching the apps with menu bar items.
/// - The positions of Icey's control items, and of every other menu bar
///   item, which AppKit saves for each status item. The order of the menu
///   bar is the system's, not a setting.
/// - Launch at Login, a login item registered with macOS rather than a
///   setting, which the user turns on for each Mac.
/// - Deprecated keys, Sparkle's update keys and window frames.
@MainActor
struct SettingsFile {
    /// The value of the file's `format` field.
    static let format = "Icey Settings"

    /// The version of the file format that this build writes.
    ///
    /// When a setting in ``entries`` changes how it is stored, bump this and
    /// convert files of the older versions in ``migrate(_:from:)``, the same
    /// way `MigrationManager` converts the stored settings.
    static let currentVersion = 1

    /// The validated values to write to UserDefaults, by key.
    let values: [Defaults.Key: Any]

    /// The number of settings in the file.
    var count: Int {
        values.count
    }

    /// Reads and validates the settings file at the given URL.
    init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        try self.init(data: data)
    }

    /// Reads and validates the given settings file data.
    ///
    /// A value of the wrong type rejects the whole file, so an import never
    /// applies only part of it. Unknown keys are ignored.
    init(data: Data) throws {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ReadError.notSettingsFile
        }
        guard
            let root = object as? [String: Any],
            root["format"] as? String == Self.format,
            let versionNumber = root["version"] as? NSNumber,
            !versionNumber.isBoolean,
            let version = Int(exactly: versionNumber.doubleValue),
            version >= 1,
            let fileSettings = root["settings"] as? [String: Any]
        else {
            throw ReadError.notSettingsFile
        }
        guard version <= Self.currentVersion else {
            throw ReadError.newerVersion
        }

        let settings = Self.migrate(fileSettings, from: version)

        var values = [Defaults.Key: Any]()
        for (key, kind) in Self.entries {
            guard let fileValue = settings[key.rawValue] else {
                continue
            }
            guard let value = kind.defaultsValue(fromFileValue: fileValue) else {
                throw ReadError.invalidValue(key: key.rawValue)
            }
            values[key] = value
        }
        guard !values.isEmpty else {
            throw ReadError.noSettings
        }
        self.values = values
    }

    /// Returns the current settings as settings file data.
    static func currentSettingsData() throws -> Data {
        var settings = [String: Any]()
        for (key, kind) in entries {
            guard
                let value = Defaults.object(forKey: key),
                let fileValue = kind.fileValue(fromDefaultsValue: value)
            else {
                continue
            }
            settings[key.rawValue] = fileValue
        }
        let root: [String: Any] = [
            "format": format,
            "version": currentVersion,
            "appVersion": Constants.versionString,
            "settings": settings,
        ]
        return try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    /// Writes the file's settings to UserDefaults.
    ///
    /// The settings models read UserDefaults only when the app starts, so
    /// the app must be relaunched afterwards.
    func apply() {
        for (key, value) in values {
            switch key {
            case .hotkeys:
                // Hotkeys missing from the file keep their current keys.
                guard let imported = value as? [String: Data] else {
                    continue
                }
                var hotkeys = Defaults.dictionary(forKey: .hotkeys) ?? [:]
                hotkeys.merge(imported) { $1 }
                Defaults.set(hotkeys, forKey: .hotkeys)
            case .macOS27Layout:
                Defaults.set(value, forKey: key)
                // A layout of the user's own must not be replaced by one read
                // from the bar. An empty layout is one too: every app visible.
                if value is [String: Int] {
                    Defaults.set(true, forKey: .macOS27LayoutSeeded)
                }
            default:
                Defaults.set(value, forKey: key)
            }
        }
    }

    /// Converts the settings of a file of an older format version to the
    /// current version.
    private static func migrate(_ settings: [String: Any], from version: Int) -> [String: Any] {
        // Version 1 is the first version, so there is nothing to convert yet.
        // Convert one version at a time, so each step stays simple:
        //
        //     var settings = settings
        //     if version < 2 { ... }
        //     return settings
        settings
    }
}

// MARK: - SettingsFile.Kind

extension SettingsFile {
    /// How a setting is stored, in UserDefaults and in the file.
    private enum Kind {
        /// A Boolean value.
        case bool
        /// A finite number.
        case double
        /// An integer that passes the given check, usually an enum's raw value.
        case integer(isValid: (Int) -> Bool)
        /// Data encoded with `JSONEncoder` in UserDefaults, and a nested JSON
        /// value in the file. The closure decodes the data as its type and
        /// encodes it again, which validates it.
        case json(normalize: (Data) throws -> Data)
        /// The hotkeys: a dictionary of `HotkeyAction` raw values to encoded
        /// optional key combinations.
        case hotkeys
        /// The macOS 27 layout: a dictionary of bundle identifiers to
        /// `MacOS27Section` raw values.
        case macOS27Layout

        /// Data encoded from the given `Codable` type.
        static func json<T: Codable>(_ type: T.Type) -> Kind {
            .json { data in
                try JSONEncoder().encode(JSONDecoder().decode(type, from: data))
            }
        }

        /// An integer that is the raw value of a case of the given enum.
        static func rawValue<T: RawRepresentable>(of type: T.Type) -> Kind where T.RawValue == Int {
            .integer { type.init(rawValue: $0) != nil }
        }

        /// Returns the value to write to the file for a value in UserDefaults.
        func fileValue(fromDefaultsValue value: Any) -> Any? {
            switch self {
            case .bool:
                return value as? Bool
            case .double:
                return value as? Double
            case .integer:
                return value as? Int
            case .json:
                return (value as? Data).flatMap(Self.jsonObject)
            case .hotkeys:
                guard let dictionary = value as? [String: Data] else {
                    return nil
                }
                return dictionary.compactMapValues(Self.jsonObject)
            case .macOS27Layout:
                return value as? [String: Int]
            }
        }

        /// Returns the value to write to UserDefaults for a value in the file,
        /// or `nil` if the value is not valid.
        func defaultsValue(fromFileValue value: Any) -> Any? {
            switch self {
            case .bool:
                guard let number = value as? NSNumber, number.isBoolean else {
                    return nil
                }
                return number.boolValue
            case .double:
                guard let number = value as? NSNumber, !number.isBoolean, number.doubleValue.isFinite else {
                    return nil
                }
                return number.doubleValue
            case .integer(let isValid):
                guard let integer = Self.integer(from: value), isValid(integer) else {
                    return nil
                }
                return integer
            case .json(let normalize):
                return Self.jsonData(from: value).flatMap { try? normalize($0) }
            case .hotkeys:
                guard let dictionary = value as? [String: Any] else {
                    return nil
                }
                var hotkeys = [String: Data]()
                for (action, value) in dictionary {
                    // Actions this version doesn't know are skipped.
                    guard HotkeyAction(rawValue: action) != nil else {
                        continue
                    }
                    guard
                        let data = Self.jsonData(from: value),
                        let keyCombination = try? JSONDecoder().decode(KeyCombination?.self, from: data),
                        let normalized = try? JSONEncoder().encode(keyCombination)
                    else {
                        return nil
                    }
                    hotkeys[action] = normalized
                }
                return hotkeys
            case .macOS27Layout:
                guard let dictionary = value as? [String: Any] else {
                    return nil
                }
                var layout = [String: Int]()
                for (bundleID, value) in dictionary {
                    guard
                        !bundleID.isEmpty,
                        let section = Self.integer(from: value),
                        MacOS27Section(rawValue: section) != nil
                    else {
                        return nil
                    }
                    layout[bundleID] = section
                }
                return layout
            }
        }

        /// Returns the integer in the given JSON value, if it holds one.
        private static func integer(from value: Any) -> Int? {
            guard let number = value as? NSNumber, !number.isBoolean else {
                return nil
            }
            return Int(exactly: number.doubleValue)
        }

        /// Decodes JSON data into a JSON value for the file.
        private static func jsonObject(from data: Data) -> Any? {
            try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        }

        /// Encodes a JSON value from the file into JSON data.
        private static func jsonData(from value: Any) -> Data? {
            // The value came from JSONSerialization, so it is valid JSON, but
            // check anyway: writing an invalid object raises an exception.
            guard value is NSNull || JSONSerialization.isValidJSONObject([value]) else {
                return nil
            }
            return try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)
        }
    }
}

// MARK: - SettingsFile Entries

extension SettingsFile {
    /// The settings that are written to and read from the file.
    private static let entries: [(key: Defaults.Key, kind: Kind)] = [
        // General
        (.showIceIcon, .bool),
        (.iceIcon, .json(ControlItemImageSet.self)),
        (.customIceIconIsTemplate, .bool),
        (.useIceBar, .bool),
        (.iceBarLocation, .rawValue(of: IceBarLocation.self)),
        (.iceBarDisplays, .rawValue(of: IceBarDisplays.self)),
        (.iceBarWidthThreshold, .double),
        (.animateIceBar, .bool),
        (.newItemPlacement, .rawValue(of: NewItemPlacement.self)),
        (.showOnClick, .bool),
        (.showOnHover, .bool),
        (.showOnScroll, .bool),
        (.autoRehide, .bool),
        (.rehideStrategy, .rawValue(of: RehideStrategy.self)),
        (.rehideInterval, .double),

        // Displays
        //
        // Keyed by display UUID. Displays that are not connected, such as
        // those of another Mac, stay listed as not connected, where they can
        // be forgotten.
        (.displayConfigurations, .json([String: DisplayConfiguration].self)),

        // Hotkeys
        (.hotkeys, .hotkeys),

        // Advanced
        (.enableAlwaysHiddenSection, .bool),
        (.showAllSectionsOnUserDrag, .bool),
        (.sectionDividerStyle, .rawValue(of: SectionDividerStyle.self)),
        (.hideApplicationMenus, .bool),
        (.enableSecondaryContextMenu, .bool),
        (.showOnHoverDelay, .double),
        (.tempShowInterval, .double),
        (.showInDockWhileSettingsOpen, .bool),

        // Appearance
        (.menuBarAppearanceConfigurationV2, .json(MenuBarAppearanceConfigurationV2.self)),

        // macOS 27
        (.macOS27Layout, .macOS27Layout),
        (.showCaptureIndicator, .bool),

        // About
        (.sendAnonymousStatistics, .bool),
    ]
}

// MARK: - SettingsFile.ReadError

extension SettingsFile {
    /// An error that prevents a settings file from being imported.
    enum ReadError: LocalizedError {
        case notSettingsFile
        case newerVersion
        case invalidValue(key: String)
        case noSettings

        var errorDescription: String? {
            switch self {
            case .notSettingsFile:
                String(localized: "The file is not an Icey settings file.")
            case .newerVersion:
                String(localized: "The file was exported by a newer version of Icey.")
            case .invalidValue(let key):
                String(localized: "The file has an invalid value for the setting “\(key)”.")
            case .noSettings:
                String(localized: "The file has no settings that this version of Icey uses.")
            }
        }

        var recoverySuggestion: String? {
            switch self {
            case .notSettingsFile, .invalidValue, .noSettings:
                String(localized: "Choose a file made with Export Settings.")
            case .newerVersion:
                String(localized: "Update Icey, then import the file again.")
            }
        }
    }
}

// MARK: - SettingsTransfer

/// Exports and imports the settings file from the settings window.
@MainActor
enum SettingsTransfer {
    private static let logger = Logger(category: "SettingsTransfer")

    /// Asks where to save the settings file, and saves it.
    static func exportSettings(from window: NSWindow?) async {
        let panel = NSSavePanel()
        panel.title = String(localized: "Export Settings")
        panel.prompt = String(localized: "Export")
        panel.nameFieldStringValue = "Icey Settings.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true

        guard await run(panel, for: window) == .OK, let url = panel.url else {
            return
        }
        do {
            try SettingsFile.currentSettingsData().write(to: url, options: .atomic)
            logger.info("Exported settings")
        } catch {
            logger.error("Error exporting settings: \(error, privacy: .public)")
            await showError(error, message: String(localized: "Icey could not export its settings."), for: window)
        }
    }

    /// Asks for a settings file, validates it and, once the user confirms,
    /// applies it and relaunches Icey.
    static func importSettings(from window: NSWindow?) async {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Import Settings")
        panel.prompt = String(localized: "Import")
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard await run(panel, for: window) == .OK, let url = panel.url else {
            return
        }

        let file: SettingsFile
        do {
            file = try SettingsFile(contentsOf: url)
        } catch {
            logger.error("Error reading settings file: \(error, privacy: .public)")
            await showError(error, message: String(localized: "Icey could not import “\(url.lastPathComponent)”."), for: window)
            return
        }

        let alert = NSAlert()
        alert.messageText = String(localized: "Import settings from “\(url.lastPathComponent)”?")
        alert.informativeText = String(
            localized: """
                Icey will replace its settings with the \(file.count) settings in this file, \
                then quit and open again to apply them. Settings that are not in the file \
                stay as they are.
                """
        )
        alert.addButton(withTitle: String(localized: "Import and Relaunch"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        guard await run(alert, for: window) == .alertFirstButtonReturn else {
            return
        }

        file.apply()
        logger.info("Imported \(file.count, privacy: .public) settings, relaunching")
        relaunch()
    }

    /// Quits Icey and opens it again.
    private static func relaunch() {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        // Wait for this process to exit first. Otherwise `open` would bring
        // the quitting copy forward instead of starting a new one.
        process.arguments = [
            "-c",
            "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"",
            Bundle.main.bundlePath,
            String(ProcessInfo.processInfo.processIdentifier),
        ]
        do {
            try process.run()
        } catch {
            logger.error("Error relaunching: \(error, privacy: .public)")
            let alert = NSAlert()
            alert.messageText = String(localized: "Icey imported the settings but could not open itself again.")
            alert.informativeText = String(localized: "Open Icey again to apply them.")
            alert.runModal()
        }
        NSApp.terminate(nil)
    }

    /// Shows an alert for the given error.
    private static func showError(_ error: any Error, message: String, for window: NSWindow?) async {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        let wrapper = LocalizedErrorWrapper(error)
        alert.informativeText = [wrapper.errorDescription, wrapper.recoverySuggestion]
            .compactMap { $0 }
            .joined(separator: " ")
        await run(alert, for: window)
    }

    /// Runs the given panel as a sheet on the given window, or as a modal
    /// window if there is none.
    private static func run(_ panel: NSSavePanel, for window: NSWindow?) async -> NSApplication.ModalResponse {
        if let window {
            await panel.beginSheetModal(for: window)
        } else {
            panel.runModal()
        }
    }

    /// Runs the given alert as a sheet on the given window, or as a modal
    /// window if there is none.
    @discardableResult
    private static func run(_ alert: NSAlert, for window: NSWindow?) async -> NSApplication.ModalResponse {
        if let window {
            await alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

// MARK: - NSNumber Helpers

private extension NSNumber {
    /// Whether the number holds a Boolean value, as JSONSerialization
    /// returns for `true` and `false`.
    var isBoolean: Bool {
        CFGetTypeID(self) == CFBooleanGetTypeID()
    }
}
