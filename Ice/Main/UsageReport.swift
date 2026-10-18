//
//  UsageReport.swift
//  Ice
//

import AppKit

/// The anonymous report that ``UsageStatisticsManager`` sends once a day.
///
/// The fields match what the statistics service accepts
/// (https://github.com/leonardovida/icey-stats). The report has no
/// identifier of any kind, so reports from one Mac can't be linked across
/// days. It never holds menu bar item names, bundle identifiers, hotkeys or
/// anything else about the user.
///
/// This file only uses Foundation and AppKit, so it can be compiled on its
/// own to check a report against a local copy of the service.
struct UsageReport: Encodable {
    /// The version of the report format.
    static let schemaVersion = 1

    /// The most features and settings the service keeps.
    static let maxFeatures = 32
    static let maxSettings = 16

    let schema = Self.schemaVersion
    var appVersion: String
    var build: Int?
    var osVersion: String
    var model: String?
    var cpuArch: String
    var cpuBrand: String?
    var cpuCores: Int
    var memoryGB: Int
    var displayCount: Int
    var hasNotch: Bool
    var language: String?
    /// Icey features, on or off, by camelCase name.
    var features = [String: Bool]()
    /// Short Icey setting values, by camelCase name.
    var settings = [String: String]()

    private enum CodingKeys: String, CodingKey {
        case schema
        case appVersion = "app_version"
        case build
        case osVersion = "os_version"
        case model
        case cpuArch = "cpu_arch"
        case cpuBrand = "cpu_brand"
        case cpuCores = "cpu_cores"
        case memoryGB = "memory_gb"
        case displayCount = "display_count"
        case hasNotch = "has_notch"
        case language
        case features
        case settings
    }

    /// Returns the JSON body to send.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

// MARK: - System Information

extension UsageReport {
    /// Creates a report with the app, macOS and hardware fields filled in,
    /// and no features or settings.
    ///
    /// Everything is read from the bundle, `ProcessInfo`, `sysctl` and
    /// `NSScreen`, so this is cheap and doesn't block.
    @MainActor
    static func withSystemInformation(bundle: Bundle = .main) -> UsageReport {
        let processInfo = ProcessInfo.processInfo
        let screens = NSScreen.screens
        return UsageReport(
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            build: (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap { Int($0) },
            osVersion: osVersionString(processInfo.operatingSystemVersion),
            model: sysctlString("hw.model").filter(matches: modelPattern),
            cpuArch: machineIsArm64 ? "arm64" : "x86_64",
            cpuBrand: sysctlString("machdep.cpu.brand_string").flatMap(cleanCPUBrand),
            cpuCores: min(max(processInfo.processorCount, 1), 256),
            memoryGB: memoryGB(bytes: processInfo.physicalMemory),
            displayCount: min(screens.count, 16),
            hasNotch: screens.contains { $0.safeAreaInsets.top > 0 },
            language: bundle.preferredLocalizations.first.flatMap(languageTag)
        )
    }

    /// The macOS version as `major.minor.patch`, without the patch when it is 0.
    static func osVersionString(_ version: OperatingSystemVersion) -> String {
        var string = "\(version.majorVersion).\(version.minorVersion)"
        if version.patchVersion != 0 {
            string += ".\(version.patchVersion)"
        }
        return string
    }

    /// A Boolean value that indicates whether the Mac has an Apple silicon
    /// processor, also when Icey runs under Rosetta.
    ///
    /// `uname` and the build architecture report the translated
    /// architecture under Rosetta, while `hw.optional.arm64` reports the
    /// machine's.
    static var machineIsArm64: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 else {
            return false
        }
        return value == 1
    }

    /// The physical memory, rounded to the nearest gigabyte.
    static func memoryGB(bytes: UInt64) -> Int {
        let gigabyte: UInt64 = 1 << 30
        let rounded = (bytes / gigabyte) + (bytes % gigabyte >= gigabyte / 2 ? 1 : 0)
        return Int(min(max(rounded, 1), 4096))
    }

    /// The processor name with surrounding spaces removed, if it is
    /// printable ASCII of 64 characters or fewer.
    static func cleanCPUBrand(_ brand: String) -> String? {
        let trimmed = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmed.isEmpty,
            trimmed.count <= 64,
            trimmed.unicodeScalars.allSatisfy({ (0x20...0x7E).contains($0.value) })
        else {
            return nil
        }
        return trimmed
    }

    /// The BCP 47 form of a localization name, such as `pt-BR` for
    /// `pt_BR`, or `nil` if it is not a language.
    static func languageTag(_ localization: String) -> String? {
        let tag = localization.replacingOccurrences(of: "_", with: "-")
        return tag.filter(matches: languagePattern)
    }

    /// Returns the string value of the given `sysctl` name.
    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0, size <= 256 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        return String(cString: buffer)
    }

    /// The hardware model identifier, such as `Mac15,10` or `MacBookPro18,3`.
    private static let modelPattern = "^[A-Za-z]+[0-9]+,[0-9]+$"

    /// A language with an optional region or script, such as `en`, `pt-BR` or `zh-Hans`.
    private static let languagePattern = "^[a-zA-Z]{2,3}(-[a-zA-Z0-9]{2,4})?$"
}

// MARK: - String Helpers

private extension Optional<String> {
    /// The string, if it matches the given regular expression.
    func filter(matches pattern: String) -> String? {
        flatMap { $0.filter(matches: pattern) }
    }
}

private extension String {
    /// The string, if it matches the given regular expression.
    func filter(matches pattern: String) -> String? {
        range(of: pattern, options: .regularExpression) != nil ? self : nil
    }
}
