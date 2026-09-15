import SwiftUI
import UIKit

//  SystemCameraPicker.swift
//  Seal
//
//  The system camera, for a handover photo or an envelope photo. The custom
//  AVFoundation controller that lived in Seal/Camera went with the chat; a
//  legacy product needs a photo taken, not a camera-forward experience, and
//  the system picker is bigger, plainer and reads better with Bigger text on.

struct SystemCameraPicker: UIViewControllerRepresentable {
    enum Source { case camera, library }
    let source: Source
    let onPick: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = source == .camera && UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onPick: (UIImage?) -> Void
        init(onPick: @escaping (UIImage?) -> Void) { self.onPick = onPick }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onPick(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onPick(nil)
        }
    }
}
