// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import UIKit

//  PersonPhotos.swift
//  Seal
//
//  A PICTURE OF EACH PERSON YOU MET, ON THIS PHONE ONLY (1.3).
//
//  Taken with the camera the day you meet, or picked from Photos. It shows
//  on People, on their page, on the envelopes written to them and in the
//  key holder lists. It is never uploaded and the person never sees it: it
//  is your memory of them, like a contact photo.
//
//  One small square JPEG per person (ProfilePhoto.squareJPEG, which also
//  drops location data) in Application Support/people/<owner hash>/, wiped
//  on sign-out (ContentView.wipeLocalAndEngines). Readable after the first
//  unlock, so a launch in the background still finds them.

@Observable
final class PersonPhotos {
    static let shared = PersonPhotos()

    private(set) var images: [String: UIImage] = [:]
    private var ownerHash: String?

    private static func directory(ownerHash: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("people", isDirectory: true)
            .appendingPathComponent(ownerHash, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func image(for personHash: String) -> UIImage? { images[personHash] }

    /// Called once the identity is known (ContentView.setupEngines).
    func load(ownerHash: String) {
        guard self.ownerHash != ownerHash else { return }
        self.ownerHash = ownerHash
        var out: [String: UIImage] = [:]
        let dir = Self.directory(ownerHash: ownerHash)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "jpg" {
            if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                out[url.deletingPathExtension().lastPathComponent] = image
            }
        }
        images = out
    }

    @discardableResult
    func set(_ image: UIImage, for personHash: String) -> Bool {
        guard let data = image.jpegData(compressionQuality: 0.9) else { return false }
        return set(data: data, for: personHash)
    }

    @discardableResult
    func set(data: Data, for personHash: String) -> Bool {
        guard let ownerHash, let jpeg = ProfilePhoto.squareJPEG(from: data) else { return false }
        let url = Self.directory(ownerHash: ownerHash).appendingPathComponent("\(personHash).jpg")
        do {
            try jpeg.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            images[personHash] = UIImage(data: jpeg)
            return true
        } catch {
            return false
        }
    }

    func remove(for personHash: String) {
        guard let ownerHash else { return }
        try? FileManager.default.removeItem(at: Self.directory(ownerHash: ownerHash).appendingPathComponent("\(personHash).jpg"))
        images[personHash] = nil
    }

    static func wipe(ownerHash: String) {
        try? FileManager.default.removeItem(at: directory(ownerHash: ownerHash))
        if shared.ownerHash == ownerHash {
            shared.ownerHash = nil
            shared.images = [:]
        }
    }
}
