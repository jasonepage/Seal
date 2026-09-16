// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Photos
import UIKit

//  MediaSaving.swift
//  Seal
//
//  SAVING WHAT WAS OPENED. After the release, a photo or a video in an
//  envelope belongs to the person it was written for, and a phone screen
//  is a poor place to keep the only copy of a picture of your father.
//  So the reveal has Save on every photo and on the video, which writes
//  the decrypted bytes into the phone's Photos with add-only permission,
//  and Share on the voice message, which hands the file to the system
//  share sheet. Nothing is saved without a tap, and nothing leaves the
//  phone except by the person's own choice in that sheet.
//
//  The owner's preview shows the same buttons. Saving your own photo to
//  your own Photos is harmless and keeps the two screens identical.

enum MediaSaving {

    enum SaveError: LocalizedError {
        case notAllowed
        case badData
        var errorDescription: String? {
            switch self {
            case .notAllowed: "Seal is not allowed to add to your Photos. You can allow it in Settings, under Seal."
            case .badData: "That file could not be read as a photo or a video."
            }
        }
    }

    private static func ensureAddPermission() async throws {
        var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }
        guard status == .authorized || status == .limited else { throw SaveError.notAllowed }
    }

    static func savePhoto(_ data: Data) async throws {
        try await ensureAddPermission()
        guard let image = UIImage(data: data) else { throw SaveError.badData }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAsset(from: image)
        }
    }

    static func saveVideo(_ data: Data) async throws {
        try await ensureAddPermission()
        let url = try tempFile(data, extension: "mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }

    /// A file in the temporary directory, for the video player and the
    /// share sheet, both of which want a URL and not bytes. The caller
    /// removes it when done, and the system clears the directory anyway.
    static func tempFile(_ data: Data, extension ext: String, name: String = UUID().uuidString) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("seal-\(name).\(ext)")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }
}
