// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

//  Hex.swift
//  Seal
//
//  Two spellings of bytes, used everywhere: lowercase hex for hashes and
//  record names, and base64url for the WebAuthn challenge comparison.
//
//  They lived at the bottom of CeremonyManager.swift. They are here so the
//  pure parts of Seal (the key split, the release machine) can be compiled
//  and tested without the app around them (tools/coretests/main.swift).

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
