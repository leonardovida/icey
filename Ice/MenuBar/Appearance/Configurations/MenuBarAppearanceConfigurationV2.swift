//
//  MenuBarAppearanceConfigurationV2.swift
//  Ice
//

import SwiftUI

struct MenuBarAppearanceConfigurationV2: Hashable {
    var lightModeConfiguration: MenuBarAppearancePartialConfiguration
    var darkModeConfiguration: MenuBarAppearancePartialConfiguration
    var staticConfiguration: MenuBarAppearancePartialConfiguration
    var shapeKind: MenuBarShapeKind
    var fullShapeInfo: MenuBarFullShapeInfo
    var splitShapeInfo: MenuBarSplitShapeInfo
    var isInset: Bool
    var isDynamic: Bool

    var hasRoundedShape: Bool {
        switch shapeKind {
        case .noShape: false
        case .full: fullShapeInfo.hasRoundedShape
        case .split: splitShapeInfo.hasRoundedShape
        }
    }

    var current: MenuBarAppearancePartialConfiguration {
        if isDynamic {
            switch SystemAppearance.current {
            case .light: lightModeConfiguration
            case .dark: darkModeConfiguration
            }
        } else {
            staticConfiguration
        }
    }
}

// MARK: Default Configuration
extension MenuBarAppearanceConfigurationV2 {
    static let defaultConfiguration = MenuBarAppearanceConfigurationV2(
        lightModeConfiguration: .defaultConfiguration,
        darkModeConfiguration: .defaultConfiguration,
        staticConfiguration: .defaultConfiguration,
        shapeKind: .noShape,
        fullShapeInfo: .default,
        splitShapeInfo: .default,
        isInset: true,
        isDynamic: false
    )
}

extension MenuBarAppearanceConfigurationV2: Codable {
    private enum CodingKeys: CodingKey {
        case lightModeConfiguration
        case darkModeConfiguration
        case staticConfiguration
        case shapeKind
        case fullShapeInfo
        case splitShapeInfo
        case isInset
        case isDynamic
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            lightModeConfiguration: container.decodeIfPresent(MenuBarAppearancePartialConfiguration.self, forKey: .lightModeConfiguration) ?? Self.defaultConfiguration.lightModeConfiguration,
            darkModeConfiguration: container.decodeIfPresent(MenuBarAppearancePartialConfiguration.self, forKey: .darkModeConfiguration) ?? Self.defaultConfiguration.darkModeConfiguration,
            staticConfiguration: container.decodeIfPresent(MenuBarAppearancePartialConfiguration.self, forKey: .staticConfiguration) ?? Self.defaultConfiguration.staticConfiguration,
            shapeKind: container.decodeIfPresent(MenuBarShapeKind.self, forKey: .shapeKind) ?? Self.defaultConfiguration.shapeKind,
            fullShapeInfo: container.decodeIfPresent(MenuBarFullShapeInfo.self, forKey: .fullShapeInfo) ?? Self.defaultConfiguration.fullShapeInfo,
            splitShapeInfo: container.decodeIfPresent(MenuBarSplitShapeInfo.self, forKey: .splitShapeInfo) ?? Self.defaultConfiguration.splitShapeInfo,
            isInset: container.decodeIfPresent(Bool.self, forKey: .isInset) ?? Self.defaultConfiguration.isInset,
            isDynamic: container.decodeIfPresent(Bool.self, forKey: .isDynamic) ?? Self.defaultConfiguration.isDynamic
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(lightModeConfiguration, forKey: .lightModeConfiguration)
        try container.encode(darkModeConfiguration, forKey: .darkModeConfiguration)
        try container.encode(staticConfiguration, forKey: .staticConfiguration)
        try container.encode(shapeKind, forKey: .shapeKind)
        try container.encode(fullShapeInfo, forKey: .fullShapeInfo)
        try container.encode(splitShapeInfo, forKey: .splitShapeInfo)
        try container.encode(isInset, forKey: .isInset)
        try container.encode(isDynamic, forKey: .isDynamic)
    }
}

// MARK: - MenuBarAppearancePartialConfiguration

struct MenuBarAppearancePartialConfiguration: Hashable {
    var hasShadow: Bool
    var hasBorder: Bool
    var borderColor: CGColor
    var borderWidth: Double
    var tintKind: MenuBarTintKind
    var tintColor: CGColor
    var tintGradient: IceGradient
}

// MARK: Default Partial Configuration
extension MenuBarAppearancePartialConfiguration {
    static let defaultConfiguration = MenuBarAppearancePartialConfiguration(
        hasShadow: false,
        hasBorder: false,
        borderColor: .black,
        borderWidth: 1,
        tintKind: .noTint,
        tintColor: .black,
        tintGradient: .defaultMenuBarTint
    )
}

// MARK: MenuBarAppearancePartialConfiguration: Codable
extension MenuBarAppearancePartialConfiguration: Codable {
    private enum CodingKeys: CodingKey {
        case hasShadow
        case hasBorder
        case borderColor
        case borderWidth
        case shapeKind
        case fullShapeInfo
        case splitShapeInfo
        case tintKind
        case tintColor
        case tintGradient
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            hasShadow: container.decodeIfPresent(Bool.self, forKey: .hasShadow) ?? Self.defaultConfiguration.hasShadow,
            hasBorder: container.decodeIfPresent(Bool.self, forKey: .hasBorder) ?? Self.defaultConfiguration.hasBorder,
            borderColor: container.decodeIfPresent(IceColor.self, forKey: .borderColor)?.cgColor ?? Self.defaultConfiguration.borderColor,
            borderWidth: container.decodeIfPresent(Double.self, forKey: .borderWidth) ?? Self.defaultConfiguration.borderWidth,
            tintKind: container.decodeIfPresent(MenuBarTintKind.self, forKey: .tintKind) ?? Self.defaultConfiguration.tintKind,
            tintColor: container.decodeIfPresent(IceColor.self, forKey: .tintColor)?.cgColor ?? Self.defaultConfiguration.tintColor,
            tintGradient: container.decodeIfPresent(IceGradient.self, forKey: .tintGradient) ?? Self.defaultConfiguration.tintGradient
        )
    }

    func encode(to encoder: Encoder) throws {
        let defaultConfiguration = Self.defaultConfiguration
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hasShadow, forKey: .hasShadow)
        try container.encode(hasBorder, forKey: .hasBorder)
        // Each color stores its ICC profile, 3-4.5 KB, so the twelve colors
        // of a configuration that keeps the defaults took 62.9 KB. Leave out
        // a color or gradient that matches the default: `init(from:)` reads a
        // missing key as the default, as has every build since 0.11.10, which
        // introduced this configuration, so an earlier build still reads the
        // same appearance after a downgrade.
        if !Self.isDefault(borderColor, defaultConfiguration.borderColor) {
            try container.encode(IceColor(cgColor: borderColor), forKey: .borderColor)
        }
        try container.encode(borderWidth, forKey: .borderWidth)
        try container.encode(tintKind, forKey: .tintKind)
        if !Self.isDefault(tintColor, defaultConfiguration.tintColor) {
            try container.encode(IceColor(cgColor: tintColor), forKey: .tintColor)
        }
        if !Self.isDefault(tintGradient, defaultConfiguration.tintGradient) {
            try container.encode(tintGradient, forKey: .tintGradient)
        }
    }

    /// Returns a Boolean value that indicates whether the given color is the
    /// given default color, in the same named color space.
    private static func isDefault(_ color: CGColor, _ defaultColor: CGColor) -> Bool {
        color == defaultColor && color.colorSpace?.name == defaultColor.colorSpace?.name
    }

    /// Returns a Boolean value that indicates whether the given gradient has
    /// the given default gradient's stops.
    private static func isDefault(_ gradient: IceGradient, _ defaultGradient: IceGradient) -> Bool {
        gradient.stops.count == defaultGradient.stops.count && zip(gradient.stops, defaultGradient.stops).allSatisfy { stop, defaultStop in
            stop.location == defaultStop.location && isDefault(stop.color, defaultStop.color)
        }
    }
}
