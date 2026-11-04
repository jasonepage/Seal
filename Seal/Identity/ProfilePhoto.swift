// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import UIKit

//  ProfilePhoto.swift
//  Seal
//
//  THE OWNER'S OWN PICTURE, ON THIS PHONE ONLY (1.3).
//
//  It replaces the initial in the owner's own ring: the You screen and the
//  button at the top of the home screen. Nothing else. It is stored in the
//  keychain under `seal.avatar.<hash>` with ThisDeviceOnly access, like every
//  other per-identity flag, and wiped on sign-out
//  (`ContentView.wipeLocalAndEngines`). It is never uploaded: not to the
//  directory, not into an envelope. So the privacy page does not change.
//
//  Showing it to the people you write to means a new field in the sealed
//  payload, which the web page at sealmessenger.com/open must learn to read
//  first. That is later work.
//
//  The picture is redrawn as a 256 pixel square JPEG before it is kept, which
//  also drops the photo's location and camera details.

@Observable
final class ProfilePhoto {
    static let shared = ProfilePhoto()

    private(set) var image: UIImage?
    private var ownerHash: String?

    private static func key(_ ownerHash: String) -> String { "seal.avatar.\(ownerHash)" }

    /// Called once the identity is known (ContentView.setupEngines).
    func load(ownerHash: String) {
        guard self.ownerHash != ownerHash else { return }
        self.ownerHash = ownerHash
        image = KeychainStore.load(Self.key(ownerHash)).flatMap { UIImage(data: $0) }
    }

    /// Keeps a new picture. Returns false if the data is not an image or the
    /// keychain refused it; the old picture then stays.
    @discardableResult
    func set(_ data: Data) -> Bool {
        guard let ownerHash, let jpeg = Self.squareJPEG(from: data),
              KeychainStore.save(jpeg, for: Self.key(ownerHash)) else { return false }
        image = UIImage(data: jpeg)
        return true
    }

    func remove() {
        guard let ownerHash else { return }
        KeychainStore.delete(Self.key(ownerHash))
        image = nil
    }

    static func wipe(ownerHash: String) {
        KeychainStore.delete(key(ownerHash))
        if shared.ownerHash == ownerHash {
            shared.ownerHash = nil
            shared.image = nil
        }
    }

    /// The centre square of the photo, drawn at `side` pixels.
    static func squareJPEG(from data: Data, side: CGFloat = 256) -> Data? {
        guard let source = UIImage(data: data) else { return nil }
        let w = source.size.width, h = source.size.height
        let s = min(w, h)
        guard s > 0 else { return nil }
        let scale = side / s
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let out = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            source.draw(in: CGRect(x: -(w - s) / 2 * scale, y: -(h - s) / 2 * scale,
                                   width: w * scale, height: h * scale))
        }
        return out.jpegData(compressionQuality: 0.8)
    }
}
