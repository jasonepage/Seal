// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import AVFoundation

//  RevealView.swift
//  Seal
//
//  THE REVEAL. The envelopes written for this person, in the owner's order.
//  Each secret keeps the sealed card's copy discipline: one Copy button,
//  the value byte for byte, the pasteboard read back and compared.
//
//  The screen itself is `RevealPager`, and it is shared with the owner's
//  preview (FamilyPreviewView), on purpose: the preview promises to show
//  exactly what the recipient sees, and the only way that promise cannot
//  drift is for both to be the same view. RevealView adds the real media
//  loader (blobs fetched and opened with the recipient's key table entry);
//  the preview adds the owner's local one. Nothing else differs.

struct RevealView: View {
    let envelopes: [EstateEngine.OpenedEnvelope]
    let estateID: String
    let ownerName: String
    @Bindable var estateEngine: EstateEngine
    @Bindable var appLock: AppLock
    let onClose: () -> Void

    var body: some View {
        RevealPager(
            pages: envelopes.map { opened in
                RevealPage(payload: opened.payload) { item in
                    try await estateEngine.openMedia(item, entry: opened.entry, estateID: estateID)
                }
            },
            ownerName: ownerName,
            emptyTitle: "Nothing addressed to you.",
            emptyLine: "The release went through, and none of the envelopes were written for this identity.",
            banner: nil,
            onClose: onClose)
    }
}

// MARK: - One page

/// One envelope as the reader sees it, plus the way to get at its media.
/// The payload is the exact struct that was sealed (Envelope.Payload).
struct RevealPage: Identifiable {
    let payload: Envelope.Payload
    let loadMedia: (MediaItem) async throws -> Data
    var id: String { "\(payload.revealOrder)|\(payload.title)|\(payload.writtenAtEpoch)" }
}

// MARK: - The pager

struct RevealPager: View {
    let pages: [RevealPage]
    let ownerName: String
    /// Shown when there is nothing to page through.
    let emptyTitle: String
    let emptyLine: String
    /// An optional line pinned above the first page. The preview uses it
    /// to say "this is a preview"; the real reveal passes nil.
    let banner: String?
    let onClose: () -> Void
    /// The preview passes an action here and gets a "Change the order"
    /// button in the toolbar. The real reveal passes nothing: a recipient
    /// reads in the owner's order.
    var onReorder: (() -> Void)? = nil

    @State private var index = 0
    @State private var photos: [String: UIImage] = [:]
    @State private var player: AVAudioPlayer?
    @State private var copied: String?
    @State private var error: String?
    /// Secrets are hidden until the person confirms it is them
    /// (AppLock.confirmReveal). Per page, so moving to the next envelope
    /// asks again.
    @State private var secretsShownFor: Set<String> = []

    var body: some View {
        NavigationStack {
            ZStack {
                SealTheme.ink.ignoresSafeArea()
                if pages.isEmpty {
                    VStack(spacing: 10) {
                        Text(emptyTitle).font(.headline).foregroundStyle(.white)
                        Text(emptyLine)
                            .font(.callout).foregroundStyle(.white.opacity(0.55)).multilineTextAlignment(.center)
                    }
                    .padding(32)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            if let banner {
                                Text(banner)
                                    // Plain white, not brass and not silver: a preview
                                    // is neither a trust moment nor a thing vouched for.
                                    .font(.callout).foregroundStyle(.white.opacity(0.7))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(14)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                            }
                            envelopeView(pages[min(index, pages.count - 1)])
                        }
                        .padding(20)
                        .frame(maxWidth: 560).frame(maxWidth: .infinity)
                        .containerRelativeFrame(.horizontal)
                    }
                }
            }
            .navigationTitle(pages.isEmpty ? "Envelopes" : "\(min(index, pages.count - 1) + 1) of \(pages.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close", action: onClose).foregroundStyle(SealTheme.brass) }
                if let onReorder, pages.count > 1 {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: onReorder) { Label("Change the order", systemImage: "arrow.up.arrow.down") }
                            .foregroundStyle(SealTheme.brass)
                    }
                }
                if pages.count > 1 {
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button { index = max(0, index - 1) } label: { Label("Previous", systemImage: "chevron.left") }
                            .disabled(index == 0)
                        Spacer()
                        Button { index = min(pages.count - 1, index + 1) } label: { Label("Next", systemImage: "chevron.right") }
                            .disabled(index >= pages.count - 1)
                    }
                }
            }
            .onChange(of: pages.count) { _, count in
                // The preview's reorder can shrink or shuffle the list under
                // us; never point past the end.
                if index >= count { index = max(0, count - 1) }
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

    private func envelopeView(_ page: RevealPage) -> some View {
        let e = page.payload
        return VStack(alignment: .leading, spacing: 18) {
            Text(e.title).font(.system(.title2, design: .rounded, weight: .semibold)).foregroundStyle(.white)
            Text("From \(ownerName), written \(Date(timeIntervalSince1970: TimeInterval(e.writtenAtEpoch)).formatted(date: .long, time: .omitted)).")
                .font(.caption).foregroundStyle(.white.opacity(0.5))
            if !e.letter.isEmpty {
                Text(e.letter)
                    .font(.body).foregroundStyle(.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(16).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
            }
            if let voice = e.voiceNote {
                Button {
                    Task { await play(voice, page: page) }
                } label: {
                    Label(player?.isPlaying == true ? "Playing" : "Play the voice message", systemImage: "play.circle.fill")
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.bordered).tint(SealTheme.brass)
                .parentTapTarget()
            }
            ForEach(e.photos) { item in
                Group {
                    if let image = photos[item.blobID] {
                        Image(uiImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 16))
                    } else {
                        RoundedRectangle(cornerRadius: 16).fill(.white.opacity(0.06)).frame(height: 180)
                            .overlay(ProgressView().tint(SealTheme.brass))
                            .task { await load(item, page: page) }
                    }
                }
            }
            if !e.secrets.isEmpty {
                Text("The secrets").font(.headline).foregroundStyle(.white).padding(.top, 6)
                if secretsShownFor.contains(page.id) {
                    ForEach(Array(e.secrets.enumerated()), id: \.offset) { _, card in
                        secretCard(card)
                    }
                } else {
                    // Hidden until the person confirms it is them. The site
                    // promises this and the screen used to show them in the
                    // clear. The count is shown so nobody thinks a hidden
                    // secret is a missing one.
                    Text(e.secrets.count == 1
                         ? "One secret is inside. It is shown after Seal checks it is you."
                         : "\(e.secrets.count) secrets are inside. They are shown after Seal checks it is you.")
                        .font(.callout).foregroundStyle(.white.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        Task {
                            if await AppLock.confirmReveal() { secretsShownFor.insert(page.id) }
                        }
                    } label: {
                        Label("Show the secrets", systemImage: "faceid").frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered).tint(SealTheme.brass)
                    .parentTapTarget()
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

    private func load(_ item: MediaItem, page: RevealPage) async {
        guard photos[item.blobID] == nil else { return }
        do {
            let data = try await page.loadMedia(item)
            if let image = UIImage(data: data) { photos[item.blobID] = image }
        } catch { self.error = error.localizedDescription }
    }

    private func play(_ item: MediaItem, page: RevealPage) async {
        do {
            let data = try await page.loadMedia(item)
            try AVAudioSession.sharedInstance().setCategory(.playback)
            let p = try AVAudioPlayer(data: data)
            p.play()
            player = p
        } catch { self.error = error.localizedDescription }
    }
}
