import CoreGraphics
import Foundation
import Testing
@testable import IceMacOS27Core

@Suite("SyntheticWindowID27")
struct SyntheticWindowID27Tests {
    @Test("The same item always gets the same identifier")
    func stable() {
        let first = SyntheticWindowID27.make(bundleID: "eu.exelban.Stats", identifier: "Item#", index: 0)
        let second = SyntheticWindowID27.make(bundleID: "eu.exelban.Stats", identifier: "Item#", index: 0)
        #expect(first == second)
    }

    @Test("Different items get different identifiers")
    func distinct() {
        let first = SyntheticWindowID27.make(bundleID: "eu.exelban.Stats", identifier: "Item#", index: 0)
        let second = SyntheticWindowID27.make(bundleID: "eu.exelban.Stats", identifier: "Item#", index: 1)
        #expect(first != second)
    }

    @Test("Synthetic identifiers are recognisable and real ones are not")
    func recognisable() {
        let synthetic = SyntheticWindowID27.make(bundleID: "ru.keepcoder.Telegram", identifier: "Item-0", index: 0)
        #expect(SyntheticWindowID27.isSynthetic(synthetic))
        #expect(!SyntheticWindowID27.isSynthetic(24))
        #expect(!SyntheticWindowID27.isSynthetic(100_000))
    }
}

@Suite("OverflowDetection27")
struct OverflowDetection27Tests {
    // Measured on macOS 27.0, built-in display: the overflow button sits at x −619…−602.
    let button = CGRect(x: -619, y: 99, width: 17, height: 30)

    @Test("Folded items overlap the overflow button")
    func folded() {
        #expect(OverflowDetection27.isInOverflow(itemFrame: CGRect(x: -649, y: 102, width: 47, height: 24), chevronFrame: button))
        #expect(OverflowDetection27.isInOverflow(itemFrame: CGRect(x: -634, y: 102, width: 24, height: 24), chevronFrame: button))
    }

    @Test("A drawn item next to the button is not folded")
    func drawnNextToButton() {
        #expect(!OverflowDetection27.isInOverflow(itemFrame: CGRect(x: -588, y: 102, width: 24, height: 24), chevronFrame: button))
    }

    @Test("Items shown left of the notch while expanded are not folded")
    func expanded() {
        #expect(!OverflowDetection27.isInOverflow(itemFrame: CGRect(x: -904, y: 102, width: 36, height: 24), chevronFrame: button))
    }

    @Test("Without an overflow button nothing is folded")
    func noButton() {
        #expect(!OverflowDetection27.isInOverflow(itemFrame: CGRect(x: 0, y: 0, width: 24, height: 24), chevronFrame: nil))
    }
}

@Suite("ClockBridgeZone27")
struct ClockBridgeZone27Tests {
    let clock = CGRect(x: 1787, y: 0, width: 113, height: 30)

    @Test("A click on a system item is bridged while concealing")
    func bridged() {
        #expect(ClockBridgeZone27.shouldBridge(click: CGPoint(x: 1840, y: 15), systemItemFrames: [clock], isConcealing: true))
    }

    @Test("A click one point outside the frame still counts")
    func edgeTolerance() {
        #expect(ClockBridgeZone27.shouldBridge(click: CGPoint(x: 1786.5, y: 15), systemItemFrames: [clock], isConcealing: true))
    }

    @Test("A click elsewhere is not bridged")
    func elsewhere() {
        #expect(!ClockBridgeZone27.shouldBridge(click: CGPoint(x: 900, y: 12), systemItemFrames: [clock], isConcealing: true))
    }

    @Test("Nothing is bridged while nothing is concealed")
    func notConcealing() {
        #expect(!ClockBridgeZone27.shouldBridge(click: CGPoint(x: 1840, y: 15), systemItemFrames: [clock], isConcealing: false))
    }

    // Measured on macOS 27.0.1 while concealed (jordanbaird/Ice#1014): Macs Fan Control's item
    // sits between the battery and Control Centre, and MenuBarAgent draws the battery over it.
    let wifi = CGRect(x: 1274, y: 0, width: 22, height: 24)
    let battery = CGRect(x: 1312, y: 0, width: 26, height: 24)
    let controlCenter = CGRect(x: 1354, y: 0, width: 26, height: 24)
    let clockAfterControlCenter = CGRect(x: 1378, y: 0, width: 113, height: 24)
    let fanControl = CGRect(x: 1315, y: 0, width: 24, height: 24)
    var systemItems: [CGRect] { [wifi, battery, controlCenter, clockAfterControlCenter] }

    @Test("A system item at or left of an overlapped one may move")
    func mayMove() {
        for clicked in [wifi, battery] {
            #expect(ClockBridgeZone27.clickedItemMayMove(
                clickedFrame: clicked,
                systemItemFrames: systemItems,
                applicationItemFrames: [fanControl]
            ))
        }
    }

    @Test("A system item right of the overlap stays where it is")
    func staysPut() {
        for clicked in [controlCenter, clockAfterControlCenter] {
            #expect(!ClockBridgeZone27.clickedItemMayMove(
                clickedFrame: clicked,
                systemItemFrames: systemItems,
                applicationItemFrames: [fanControl]
            ))
        }
    }

    @Test("Neighbours overlapping by the usual 2 points do not count")
    func neighbours() {
        let leftNeighbour = CGRect(x: 1254, y: 0, width: 22, height: 24)
        #expect(!ClockBridgeZone27.clickedItemMayMove(
            clickedFrame: wifi,
            systemItemFrames: systemItems,
            applicationItemFrames: [leftNeighbour]
        ))
    }

    @Test("An item on another display does not count")
    func otherDisplay() {
        let elsewhere = fanControl.offsetBy(dx: 0, dy: 1000)
        #expect(!ClockBridgeZone27.clickedItemMayMove(
            clickedFrame: battery,
            systemItemFrames: systemItems,
            applicationItemFrames: [elsewhere]
        ))
    }

    @Test("A replayed click keeps its place within the item that moved")
    func relocated() {
        // Lifted, the battery moved from 1312 to 1274 (#1014).
        let moved = battery.offsetBy(dx: -38, dy: 0)
        let point = ClockBridgeZone27.relocatedClick(CGPoint(x: 1325, y: 12), from: battery, to: moved)
        #expect(point == CGPoint(x: 1287, y: 12))
        #expect(moved.contains(point))
    }
}

@Suite("ItemHitTest27")
struct ItemHitTest27Tests {
    // Measured on macOS 27.0 with the external menu bar active.
    let stats = ItemHitTest27.Item(frame: CGRect(x: 1478, y: 2, width: 33, height: 24), ownerPID: 100, isOnScreen: true)
    let clock = CGRect(x: 1787, y: 0, width: 113, height: 30)
    // Built-in display: an item folded behind the overflow button, and the button itself.
    let folded = ItemHitTest27.Item(frame: CGRect(x: -649, y: 102, width: 47, height: 24), ownerPID: 200, isOnScreen: false)
    let overflowButton = CGRect(x: -619.5, y: 99, width: 17.5, height: 30)

    @Test("The pointer on a drawn item is inside an item")
    func drawnItem() {
        #expect(ItemHitTest27.isInsideItem(point: CGPoint(x: 1497, y: 14), items: [stats], concealedPIDs: [], systemFrames: [clock]))
    }

    @Test("An empty spot is not inside an item")
    func emptySpot() {
        #expect(!ItemHitTest27.isInsideItem(point: CGPoint(x: 900, y: 12), items: [stats], concealedPIDs: [], systemFrames: [clock]))
    }

    @Test("A concealed item's stale frame does not count")
    func concealed() {
        #expect(!ItemHitTest27.isInsideItem(point: CGPoint(x: 1497, y: 14), items: [stats], concealedPIDs: [100], systemFrames: []))
    }

    @Test("A folded item does not count, but the overflow button does")
    func overflow() {
        #expect(!ItemHitTest27.isInsideItem(point: CGPoint(x: -640, y: 114), items: [folded], concealedPIDs: [], systemFrames: []))
        #expect(ItemHitTest27.isInsideItem(point: CGPoint(x: -611, y: 114), items: [folded], concealedPIDs: [], systemFrames: [overflowButton]))
    }

    @Test("System items count on either display")
    func systemItems() {
        #expect(ItemHitTest27.isInsideItem(point: CGPoint(x: 1843, y: 12), items: [], concealedPIDs: [], systemFrames: [clock]))
    }
}

@Suite("AccessibilityScanSchedule27")
struct AccessibilityScanSchedule27Tests {
    @Test("A process is asked with the normal timeout")
    func normal() {
        let schedule = AccessibilityScanSchedule27()
        #expect(schedule.timeout(for: 10, now: 0) == AccessibilityScanSchedule27.normalTimeout)
    }

    @Test("A process that timed out is skipped for a minute, then retried briefly")
    func backoff() {
        var schedule = AccessibilityScanSchedule27()
        schedule.record(pid: 10, timedOut: true, now: 0)
        #expect(schedule.timeout(for: 10, now: 1) == nil)
        #expect(schedule.timeout(for: 10, now: 59) == nil)
        #expect(schedule.timeout(for: 10, now: 60) == AccessibilityScanSchedule27.retryTimeout)
        schedule.record(pid: 10, timedOut: true, now: 60)
        #expect(schedule.timeout(for: 10, now: 179) == nil)
        #expect(schedule.timeout(for: 10, now: 180) == AccessibilityScanSchedule27.retryTimeout)
    }

    @Test("The pause stops growing at ten minutes")
    func cap() {
        var schedule = AccessibilityScanSchedule27()
        var now: TimeInterval = 0
        for _ in 0..<8 {
            schedule.record(pid: 10, timedOut: true, now: now)
            while schedule.timeout(for: 10, now: now) == nil {
                now += 1
            }
        }
        schedule.record(pid: 10, timedOut: true, now: now)
        #expect(schedule.timeout(for: 10, now: now + 599) == nil)
        #expect(schedule.timeout(for: 10, now: now + 600) == AccessibilityScanSchedule27.retryTimeout)
    }

    @Test("A process that answers is asked normally again")
    func recovery() {
        var schedule = AccessibilityScanSchedule27()
        schedule.record(pid: 10, timedOut: true, now: 0)
        schedule.record(pid: 10, timedOut: false, now: 60)
        #expect(schedule.timeout(for: 10, now: 61) == AccessibilityScanSchedule27.normalTimeout)
    }

    @Test("A process that has shown items is never skipped")
    func itemOwners() {
        var schedule = AccessibilityScanSchedule27()
        schedule.recordItems(pid: 10)
        schedule.record(pid: 10, timedOut: true, now: 0)
        #expect(schedule.timeout(for: 10, now: 1) == AccessibilityScanSchedule27.normalTimeout)
    }

    @Test("An exited item owner is forgotten too")
    func exitedItemOwner() {
        var schedule = AccessibilityScanSchedule27()
        schedule.recordItems(pid: 10)
        schedule.retain(running: [11])
        schedule.record(pid: 10, timedOut: true, now: 0)
        #expect(schedule.timeout(for: 10, now: 1) == nil)
    }

    @Test("Exited processes are forgotten, so a reused identifier starts fresh")
    func forgetting() {
        var schedule = AccessibilityScanSchedule27()
        schedule.record(pid: 10, timedOut: true, now: 0)
        schedule.retain(running: [11])
        #expect(schedule.timeout(for: 10, now: 1) == AccessibilityScanSchedule27.normalTimeout)
    }
}
