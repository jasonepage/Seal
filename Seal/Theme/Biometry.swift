// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import LocalAuthentication

//  Biometry.swift
//  Seal
//
//  THE NAME OF THIS DEVICE'S OWN CHECK: Face ID, Touch ID, Optic ID, or the
//  passcode. Screens used to say "Face ID" everywhere, which is wrong on an
//  iPhone SE or a Touch ID iPad; a TestFlight tester's iPad 8 offered "Set up
//  with Face ID". Used for THIS device only. Screens about someone else's
//  phone say "Face ID or Touch ID", because this phone cannot know theirs.

enum Biometry {
    enum Kind { case faceID, touchID, opticID, none }

    /// The hardware this device has. `biometryType` is filled in by
    /// `canEvaluatePolicy`, whatever that call returns, so this is right
    /// even before the person has enrolled a face or a finger.
    static let kind: Kind = {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return .faceID
        case .touchID: return .touchID
        case .opticID: return .opticID
        default: return .none
        }
    }()

    /// For the middle of a sentence: "Face ID", "Touch ID", "Optic ID", or
    /// "your passcode".
    static var name: String {
        switch kind {
        case .faceID: "Face ID"
        case .touchID: "Touch ID"
        case .opticID: "Optic ID"
        case .none: "your passcode"
        }
    }

    /// For the start of a line or a button: as `name`, but "Passcode".
    static var title: String {
        kind == .none ? "Passcode" : name
    }

    /// The matching SF Symbol.
    static var symbol: String {
        switch kind {
        case .faceID: "faceid"
        case .touchID: "touchid"
        case .opticID: "opticid"
        case .none: "lock.fill"
        }
    }
}
