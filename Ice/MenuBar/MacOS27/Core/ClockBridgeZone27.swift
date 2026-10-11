//
//  ClockBridgeZone27.swift
//  Ice
//

import CoreGraphics

/// Decides whether a click must be let through to a system item.
///
/// While an assessment-mode assertion is live, MenuBarAgent ignores clicks on
/// the clock (measured on macOS 27.0), so such clicks lift the assertion first.
enum ClockBridgeZone27 {
    static func shouldBridge(click: CGPoint, systemItemFrames: [CGRect], isConcealing: Bool) -> Bool {
        guard isConcealing else {
            return false
        }
        return systemItemFrames.contains { $0.insetBy(dx: -1, dy: -1).contains(click) }
    }

    /// Whether the clicked system item may move once concealment is lifted.
    ///
    /// An application's item can sit among the system items. While Ice conceals, MenuBarAgent
    /// draws the system items over it, and their frames overlap; lifting concealment gives that
    /// item its slot back, and every system item left of it moves left. A click replayed where it
    /// was made then lands on the wrong item: on the battery it opened the application, and on
    /// Wi-Fi it opened the battery (measured on macOS 27.0.1, reported as jordanbaird/Ice#1014).
    ///
    /// - Parameters:
    ///   - clickedFrame: The frame of the clicked system item, while concealed.
    ///   - systemItemFrames: The frames of the system items on the same bar.
    ///   - applicationItemFrames: The frames applications report for their items, concealed or not.
    static func clickedItemMayMove(clickedFrame: CGRect, systemItemFrames: [CGRect], applicationItemFrames: [CGRect]) -> Bool {
        // Items laid out side by side overlap by 2 points (measured on macOS 27.0); an item drawn
        // over by a system item shares most of its width with it (23 points in #1014).
        let tolerance: CGFloat = 6
        return systemItemFrames.contains { system in
            guard system.minX >= clickedFrame.minX - 1 else {
                return false
            }
            return applicationItemFrames.contains { application in
                let overlap = system.intersection(application)
                return !overlap.isNull && overlap.width > tolerance
            }
        }
    }

    /// Where to replay a click on an item that moved from one frame to another, keeping the
    /// click's place within the item.
    static func relocatedClick(_ click: CGPoint, from before: CGRect, to after: CGRect) -> CGPoint {
        CGPoint(x: click.x + (after.minX - before.minX), y: click.y + (after.minY - before.minY))
    }
}
