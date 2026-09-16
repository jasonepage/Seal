// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import UIKit
import AVFoundation
import UniformTypeIdentifiers

//  VideoRecorderPicker.swift
//  Seal
//
//  THE SYSTEM CAMERA, FOR A VIDEO MESSAGE. The same reasoning as
//  SystemCameraPicker: the system recorder is big, plain and reads well
//  with Bigger text on, and it already knows how to hold a phone steady
//  for somebody over sixty. Capped at one minute and medium quality, so
//  a message is a few tens of megabytes at most and seals, uploads and
//  opens in reasonable time on a family phone.
//
//  Returns the file's bytes (an MP4 or MOV, whatever iOS wrote). The
//  bytes are encrypted under the envelope's content key like a photo;
//  nothing about the video is inspected or sent anywhere else.

struct VideoRecorderPicker: UIViewControllerRepresentable {
    static let maximumSeconds: TimeInterval = 60
    /// A hard ceiling on the bytes accepted, so a phone that ignores the
    /// duration cap (a chosen library clip) cannot seal a film.
    static let maximumBytes = 80 * 1024 * 1024

    let onPick: (Data?, String?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        let canRecord = UIImagePickerController.isSourceTypeAvailable(.camera)
        picker.sourceType = canRecord ? .camera : .photoLibrary
        picker.mediaTypes = [UTType.movie.identifier]
        if canRecord {
            picker.cameraCaptureMode = .video
            picker.cameraDevice = .front
        }
        picker.videoMaximumDuration = Self.maximumSeconds
        picker.videoQuality = .typeMedium
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onPick: (Data?, String?) -> Void
        init(onPick: @escaping (Data?, String?) -> Void) { self.onPick = onPick }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let url = info[.mediaURL] as? URL, let data = try? Data(contentsOf: url) else {
                onPick(nil, "The recording could not be read.")
                return
            }
            guard data.count <= VideoRecorderPicker.maximumBytes else {
                onPick(nil, "That video is too big to seal. Keep it under a minute.")
                return
            }
            onPick(data, nil)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onPick(nil, nil)
        }
    }
}
