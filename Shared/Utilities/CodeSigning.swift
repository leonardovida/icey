//
//  CodeSigning.swift
//  Shared
//

import Security

/// Information about the code signature of the current process.
enum CodeSigning {
    /// The team identifier of the current process, or `nil` if the process
    /// is unsigned or ad hoc signed.
    static let teamIdentifier: String? = {
        var code: SecCode?
        guard
            SecCodeCopySelf([], &code) == errSecSuccess,
            let code
        else {
            return nil
        }

        var staticCode: SecStaticCode?
        guard
            SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
            let staticCode
        else {
            return nil
        }

        var info: CFDictionary?
        guard
            SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
            let info = info as? [String: Any],
            let team = info[kSecCodeInfoTeamIdentifier as String] as? String,
            !team.isEmpty
        else {
            return nil
        }

        return team
    }()
}
