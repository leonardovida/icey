//
//  IceBarDisplays.swift
//  Ice
//

import SwiftUI

/// The displays on which the Ice Bar is used.
///
/// On every other display, hidden items are shown in the menu bar, as if
/// "Use Ice Bar" were off. A Mac with a notch has little room in the menu bar,
/// while an external display usually has plenty (jordanbaird/Ice#223, #703).
enum IceBarDisplays: Int, CaseIterable, Identifiable {
    /// The Ice Bar is used on every display.
    case all = 0

    /// The Ice Bar is used only on displays with a notch.
    case withNotch = 1

    /// The Ice Bar is used only on the built-in display.
    case builtIn = 2

    /// The Ice Bar is used only on displays narrower than a width threshold,
    /// so a wide display shows hidden items in the menu bar
    /// (jordanbaird/Ice#795, #413).
    case narrowerThan = 3

    /// The default width threshold for ``narrowerThan``, in points.
    ///
    /// Built-in displays are narrower than this at their default resolution
    /// (1512 to 1728 points on a MacBook Pro), while most external displays
    /// are at least 1920 points wide.
    static let defaultWidthThreshold: Double = 1800

    /// The width thresholds the user can choose, in points.
    static let widthThresholdRange: ClosedRange<Double> = 800...8000

    var id: Int { rawValue }

    /// Localized string key representation.
    var localized: LocalizedStringKey {
        switch self {
        case .all: "All displays"
        case .withNotch: "Displays with a notch"
        case .builtIn: "Built-in display"
        case .narrowerThan: "Displays narrower than…"
        }
    }

    /// Returns a Boolean value that indicates whether the Ice Bar is used on
    /// the given screen. Without a screen, only ``all`` uses it.
    ///
    /// - Parameters:
    ///   - screen: The screen to check.
    ///   - widthThreshold: The width, in points, below which ``narrowerThan``
    ///     uses the Ice Bar.
    func includes(_ screen: NSScreen?, widthThreshold: Double) -> Bool {
        switch self {
        case .all: true
        case .withNotch: screen?.hasNotch ?? false
        case .builtIn: screen?.isBuiltIn ?? false
        case .narrowerThan: screen.map { Double($0.frame.width) < widthThreshold } ?? false
        }
    }
}
