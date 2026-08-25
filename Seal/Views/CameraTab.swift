import SwiftUI
import AVFoundation
import PhotosUI

/// Capture-first camera (UI.md §3.4): shutter, flip, then a sealed-send tray.
///
/// Also presented as a cover from inside a chat, which is how photos survive
/// Parent Mode collapsing the tab bar (docs/UI.md §Parent Mode). Rather than
/// building a second, smaller photo UI for that case, the chat opens THIS one
/// with the destination chat pre-selected and a way back out. Both hooks
/// default to nil, so the tab behaves exactly as before.
struct CameraTab: View {
    let myRoot: RootIdentity
    @Bindable var chatEngine: ChatEngine
    @Bindable var friendStore: FriendStore
    /// Pre-ticked in the send tray when opened from a chat — you are already
    /// in the conversation you meant to send to.
    var preselectedChat: ChatEngine.Chat? = nil
    /// Non-nil when presented as a cover: draws a close button and dismisses
    /// after a successful send.
    var onClose: (() -> Void)? = nil

    @State private var camera = CameraController()
    @State private var captured: UIImage?
    @State private var libraryItem: PhotosPickerItem?

    var body: some View {
        ZStack {
            SealTheme.ink.ignoresSafeArea()
            if let captured {
                SendTray(image: captured, myRoot: myRoot, chatEngine: chatEngine,
                         preselected: preselectedChat?.id,
                         onSent: onClose) {
                    self.captured = nil
                }
            } else {
                cameraView
            }
        }
        .preferredColorScheme(.dark)
        .task { await camera.start() }
        .onDisappear { camera.stop() }
        .onChange(of: libraryItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    captured = image
                }
                libraryItem = nil
            }
        }
    }

    private var cameraView: some View {
        ZStack {
            if camera.authorized {
                CameraPreview(session: camera.session)
                    .ignoresSafeArea()
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.white.opacity(0.3))
                    Text("Allow camera access in Settings,\nor pick from your library below.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                }
            }

            VStack {
                Spacer()
                HStack {
                    PhotosPicker(selection: $libraryItem, matching: .images) {
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 24))
                            .foregroundStyle(.white)
                            .frame(width: 52, height: 52)
                            .background(.black.opacity(0.4), in: Circle())
                    }
                    Spacer()
                    // Shutter
                    Button {
                        Task { captured = await camera.capture() }
                    } label: {
                        ZStack {
                            Circle().strokeBorder(SealTheme.brass, lineWidth: 4)
                                .frame(width: 76, height: 76)
                            Circle().fill(.white)
                                .frame(width: 62, height: 62)
                        }
                    }
                    Spacer()
                    Button {
                        camera.flip()
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath.camera")
                            .font(.system(size: 24))
                            .foregroundStyle(.white)
                            .frame(width: 52, height: 52)
                            .background(.black.opacity(0.4), in: Circle())
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 24)
            }

            // Only when this is a cover over a chat. As a tab there is nothing
            // to close and the tab bar is the way out.
            if let onClose {
                VStack {
                    HStack {
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 52, height: 52)
                                .background(.black.opacity(0.4), in: Circle())
                        }
                        .accessibilityLabel("Close the camera")
                        Spacer()
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }
        }
    }
}

/// After capture: preview + pick sealed chats + send with encryption shimmer.
private struct SendTray: View {
    let image: UIImage
    let myRoot: RootIdentity
    @Bindable var chatEngine: ChatEngine
    var preselected: UUID? = nil
    /// Called after a successful send, in addition to `onDone` — the cover
    /// presentation uses it to dismiss itself.
    var onSent: (() -> Void)? = nil
    let onDone: () -> Void

    @State private var selected: Set<UUID> = []
    @State private var sending = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 420)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .padding(.horizontal, 16)
                    .overlay {
                        if sending {
                            RoundedRectangle(cornerRadius: 20)
                                .fill(.black.opacity(0.5))
                                .padding(.horizontal, 16)
                            VStack(spacing: 8) {
                                ProgressView().tint(SealTheme.brass)
                                Text("Sealing…")
                                    .font(.caption)
                                    .foregroundStyle(SealTheme.brass)
                            }
                        }
                    }
                Button { onDone() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.white.opacity(0.8))
                }
                .padding(.leading, 28)
                .padding(.top, 12)
            }
            .padding(.top, 16)

            Text("Send sealed to")
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 16)

            List {
                ForEach(chatEngine.chats) { chat in
                    Button {
                        if selected.contains(chat.id) { selected.remove(chat.id) }
                        else { selected.insert(chat.id) }
                    } label: {
                        HStack {
                            Text(chat.name).foregroundStyle(.white)
                            Spacer()
                            Image(systemName: selected.contains(chat.id)
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected.contains(chat.id)
                                                 ? SealTheme.brass : .white.opacity(0.3))
                        }
                    }
                    .listRowBackground(Color.white.opacity(0.05))
                }
            }
            .scrollContentBackground(.hidden)

            Button {
                Task { await send() }
            } label: {
                Label(sending ? "Sealing…" : "Send", systemImage: "arrow.up.circle.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(SealTheme.brass)
            .disabled(sending || selected.isEmpty)
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        // Opened from a chat: that chat starts ticked, so the common case is
        // capture → Send with nothing else to understand.
        .onAppear {
            if let preselected { selected.insert(preselected) }
        }
    }

    private func send() async {
        sending = true
        defer { sending = false }
        // Downscale: keep uploads quick and well under asset comfort zones.
        let jpeg = image.scaledJPEG(maxDimension: 1600, quality: 0.8)
        for chat in chatEngine.chats where selected.contains(chat.id) {
            await chatEngine.sendPhoto(jpeg, in: chat, from: myRoot)
        }
        onDone()
        onSent?()
    }
}

/// Live AVCaptureSession preview.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

extension UIImage {
    func scaledJPEG(maxDimension: CGFloat, quality: CGFloat) -> Data {
        let longest = max(size.width, size.height)
        guard longest > maxDimension else { return jpegData(compressionQuality: quality) ?? Data() }
        let scale = maxDimension / longest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized = renderer.image { _ in draw(in: CGRect(origin: .zero, size: newSize)) }
        return resized.jpegData(compressionQuality: quality) ?? Data()
    }
}
