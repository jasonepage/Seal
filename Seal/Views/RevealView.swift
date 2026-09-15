import SwiftUI
import AVFoundation

//  RevealView.swift
//  Seal
//
//  THE REVEAL. The envelopes written for this person, in the owner's order.
//  Each secret keeps the sealed card's copy discipline: one Copy button,
//  the value byte for byte, the pasteboard read back and compared.

struct RevealView: View {
    let envelopes: [EstateEngine.OpenedEnvelope]
    let estateID: String
    let ownerName: String
    @Bindable var estateEngine: EstateEngine
    @Bindable var appLock: AppLock
    let onClose: () -> Void

    @State private var index = 0
    @State private var photos: [String: UIImage] = [:]
    @State private var player: AVAudioPlayer?
    @State private var copied: String?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ZStack {
                SealTheme.ink.ignoresSafeArea()
                if envelopes.isEmpty {
                    VStack(spacing: 10) {
                        Text("Nothing addressed to you.").font(.headline).foregroundStyle(.white)
                        Text("The release went through, and none of the envelopes were written for this identity.")
                            .font(.callout).foregroundStyle(.white.opacity(0.55)).multilineTextAlignment(.center)
                    }
                    .padding(32)
                } else {
                    ScrollView {
                        envelopeView(envelopes[index])
                            .padding(20)
                            .frame(maxWidth: 560).frame(maxWidth: .infinity)
                            .containerRelativeFrame(.horizontal)
                    }
                }
            }
            .navigationTitle(envelopes.isEmpty ? "Envelopes" : "\(index + 1) of \(envelopes.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close", action: onClose).foregroundStyle(SealTheme.brass) }
                if envelopes.count > 1 {
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button { index = max(0, index - 1) } label: { Label("Previous", systemImage: "chevron.left") }
                            .disabled(index == 0)
                        Spacer()
                        Button { index = min(envelopes.count - 1, index + 1) } label: { Label("Next", systemImage: "chevron.right") }
                            .disabled(index == envelopes.count - 1)
                    }
                }
            }
            .alert("Copied", isPresented: Binding(get: { copied != nil }, set: { if !$0 { copied = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(copied ?? "") }
            .alert("Seal", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
        }
        .preferredColorScheme(.dark)
    }

    private func envelopeView(_ e: EstateEngine.OpenedEnvelope) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(e.payload.title).font(.system(.title2, design: .rounded, weight: .semibold)).foregroundStyle(.white)
            Text("From \(ownerName), written \(Date(timeIntervalSince1970: TimeInterval(e.payload.writtenAtEpoch)).formatted(date: .long, time: .omitted)).")
                .font(.caption).foregroundStyle(.white.opacity(0.5))
            if !e.payload.letter.isEmpty {
                Text(e.payload.letter)
                    .font(.body).foregroundStyle(.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(16).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
            }
            if let voice = e.payload.voiceNote {
                Button {
                    Task { await play(voice, entry: e.entry) }
                } label: {
                    Label(player?.isPlaying == true ? "Playing" : "Play the voice message", systemImage: "play.circle.fill")
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.bordered).tint(SealTheme.brass)
                .parentTapTarget()
            }
            ForEach(e.payload.photos) { item in
                Group {
                    if let image = photos[item.blobID] {
                        Image(uiImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 16))
                    } else {
                        RoundedRectangle(cornerRadius: 16).fill(.white.opacity(0.06)).frame(height: 180)
                            .overlay(ProgressView().tint(SealTheme.brass))
                            .task { await load(item, entry: e.entry) }
                    }
                }
            }
            if !e.payload.secrets.isEmpty {
                Text("The secrets").font(.headline).foregroundStyle(.white).padding(.top, 6)
                ForEach(Array(e.payload.secrets.enumerated()), id: \.offset) { _, card in
                    secretCard(card)
                }
            }
            Text("Everything above was sealed by \(ownerName)'s phone and could not be read by anyone, including Seal, until the custodians combined their keys. The letter is theirs. Check the secrets carefully before acting on them.")
                .font(.caption2).foregroundStyle(.white.opacity(0.4)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func secretCard(_ card: SealedCard) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(card.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
            Text(card.typeLine).font(.caption2).foregroundStyle(.white.opacity(0.5))
            Text(card.displayValue)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.white.opacity(0.95))
                .fixedSize(horizontal: false, vertical: true)
            if let note = card.note, !note.isEmpty {
                Text(note).font(.callout).foregroundStyle(.white.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
            }
            Button {
                UIPasteboard.general.string = card.value
                if let back = UIPasteboard.general.string {
                    copied = back == card.value
                        ? SealedCard.copyConfirmation(for: back)
                        : "Something changed the clipboard between the copy and the check. Do not paste it."
                } else {
                    copied = "Copied, but the clipboard would not confirm what it holds. Check before you paste."
                }
            } label: { Label(card.cardType.copyLabel, systemImage: "doc.on.doc").frame(maxWidth: .infinity) }
            .buttonStyle(.bordered).tint(SealTheme.brass)
            .parentTapTarget()
        }
        .padding(16)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
    }

    private func load(_ item: MediaItem, entry: KeyTableEntry) async {
        guard photos[item.blobID] == nil else { return }
        do {
            let data = try await estateEngine.openMedia(item, entry: entry, estateID: estateID)
            if let image = UIImage(data: data) { photos[item.blobID] = image }
        } catch { self.error = error.localizedDescription }
    }

    private func play(_ item: MediaItem, entry: KeyTableEntry) async {
        do {
            let data = try await estateEngine.openMedia(item, entry: entry, estateID: estateID)
            try AVAudioSession.sharedInstance().setCategory(.playback)
            let p = try AVAudioPlayer(data: data)
            p.play()
            player = p
        } catch { self.error = error.localizedDescription }
    }
}
