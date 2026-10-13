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

    var id: Int { rawValue }

    /// Localized string key representation.
    var localized: LocalizedStringKey {
        switch self {
        case .all: "All displays"
        case .withNotch: "Displays with a notch"
        case .builtIn: "Built-in display"
        }
    }

    /// Returns a Boolean value that indicates whether the Ice Bar is used on
    /// the given screen. Without a screen, only ``all`` uses it.
    func includes(_ screen: NSScreen?) -> Bool {
        switch self {
        case .all: true
        case .withNotch: screen?.hasNotch ?? false
        case .builtIn: screen?.isBuiltIn ?? false
        }
    }
}
