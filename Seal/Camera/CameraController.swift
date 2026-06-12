import AVFoundation
import UIKit

/// Thin AVFoundation wrapper: live preview session + single photo capture.
@Observable
final class CameraController: NSObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private var position: AVCaptureDevice.Position = .back
    private var continuation: CheckedContinuation<UIImage?, Never>?
    private(set) var authorized = false
    private var configured = false

    func start() async {
        authorized = await AVCaptureDevice.requestAccess(for: .video)
        guard authorized else { return }
        if !configured { configure() }
        guard configured else { return }
        let session = self.session
        Task.detached { if !session.isRunning { session.startRunning() } }
    }

    func stop() {
        let session = self.session
        Task.detached { if session.isRunning { session.stopRunning() } }
    }

    func flip() {
        position = position == .back ? .front : .back
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        addInput()
        session.commitConfiguration()
    }

    /// One shot; returns nil on failure (no camera in Simulator, etc.).
    func capture() async -> UIImage? {
        guard configured else { return nil }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        let image = photo.fileDataRepresentation().flatMap(UIImage.init)
        continuation?.resume(returning: image)
        continuation = nil
    }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .photo
        addInput()
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        configured = !session.inputs.isEmpty
    }

    private func addInput() {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)
    }
}
