//
//  MenuBarItemService.swift
//  Shared
//

import Foundation
import XPC

enum MenuBarItemService {
    static let name = "com.jordanbaird.Ice.MenuBarItemService"
}

extension MenuBarItemService {
    /// Returns the requirement that a peer on the other end of the XPC
    /// connection must satisfy.
    ///
    /// When the current process is signed with a team identifier, the peer
    /// must be signed by the same team. Ad hoc signed builds have no team
    /// identifier, so a same-team requirement can never be satisfied and
    /// would reject every connection. For those builds, the peer must be
    /// signed with the given signing identifier instead.
    ///
    /// - Parameter signingIdentifier: The signing identifier of the expected
    ///   peer, used when the current process has no team identifier.
    @available(macOS 26.0, *)
    static func peerRequirement(signingIdentifier: String) -> XPCPeerRequirement {
        if CodeSigning.teamIdentifier != nil {
            return .isFromSameTeam()
        }
        var requirement = XPCDictionary()
        requirement["signing-identifier"] = signingIdentifier
        return XPCPeerRequirement(lightweightCodeRequirements: requirement)
    }
}

extension MenuBarItemService {
    enum Request: Codable {
        case start
        case sourcePID(WindowInfo)
        /// Asks for the source process of each of the given windows.
        ///
        /// A service from a version of the app before this request was
        /// added does not reply to it, and the app then asks for one
        /// window at a time with `sourcePID`.
        case sourcePIDs([WindowInfo])
    }

    enum Response: Codable {
        case start
        case sourcePID(pid_t?)
        /// The source process of each requested window, in order.
        case sourcePIDs([pid_t?])
    }
}
