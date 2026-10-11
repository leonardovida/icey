// usage: new-windows snapshot <file> | new-windows diff <file>
// "diff" prints "<external|builtin> <owner>" for each on-screen window taller than 40 pt that
// was not in the snapshot, other than Icey's (matched by bundle identifier, so the app's name
// does not matter).
import AppKit

func windows() -> [[String: Any]] {
    (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
}
let arguments = CommandLine.arguments
if arguments[1] == "snapshot" {
    let numbers = windows().compactMap { $0[kCGWindowNumber as String] as? Int }.map(String.init)
    try! numbers.joined(separator: "\n").write(toFile: arguments[2], atomically: true, encoding: .utf8)
} else {
    let icePIDs = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.jordanbaird.Ice").map(\.processIdentifier))
    let old = Set(((try? String(contentsOfFile: arguments[2], encoding: .utf8)) ?? "").split(separator: "\n").map(String.init))
    for window in windows() {
        guard let number = window[kCGWindowNumber as String] as? Int, !old.contains(String(number)) else {
            continue
        }
        let owner = window[kCGWindowOwnerName as String] as? String ?? "?"
        let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t ?? 0
        let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
        guard !icePIDs.contains(ownerPID), (bounds["Height"] ?? 0) > 40 else {
            continue
        }
        let centerX = (bounds["X"] ?? 0) + (bounds["Width"] ?? 0) / 2
        print("\(centerX < 0 ? "builtin" : "external") \(owner)")
    }
}
