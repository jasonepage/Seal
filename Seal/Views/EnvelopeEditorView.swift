// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import AVFoundation

//  EnvelopeEditorView.swift
//  Seal
//
//  WRITE AN ENVELOPE. Not a form: a box being packed for one person.
//
//  Karen will see, in this order: the letter, your voice, a video, the
//  photos, what to do first, the secrets. The person first, then the
//  tasks. So the editor is those six cards in that order (RevealPager
//  draws them in the same order; keep the two together). A card with something in it shows that something small
//  (the first lines of the letter, the numbered steps, the photo strip);
//  a card with nothing in it says, in one line, why she would want it.
//  At the top, one sentence says what the box holds and what it is
//  missing, and six dots fill in as it fills. When all six are lit it
//  says so.
//
//  Every edit un-seals the envelope; the home screen's Seal button
//  publishes it again. Secrets are `SealedCard`s: the same rules that kept
//  a payment address exact keep a seed phrase exact.

struct EnvelopeEditorView: View {
    @State var envelope: Envelope
    @Bindable var estateEngine: EstateEngine
    @Bindable var friendStore: FriendStore
    @Bindable var appLock: AppLock
    let onClose: () -> Void
    /// Opens the person picker for an envelope written to a typed name.
    /// Optional so nothing else that builds this view has to change.
    var onChoosePerson: (() -> Void)? = nil
    /// The owner's own name, for the "From ..." line in the preview. The
    /// preview shows the recipient's screen, and that line is on it.
    var ownerName: String = ""

    @State private var showSecretEditor = false
    @State private var showPhotoPicker = false
    @State private var showVoice = false
    @State private var showVideo = false
    @State private var showVideoPlayer = false
    @State private var videoThumbnail: UIImage?
    @State private var confirmDelete = false
    @State private var showPreview = false
    @State private var showFirstSteps = false
    @Environment(\.parentMode) private var parentMode
    @State private var revealSecrets = false
    @State private var error: String?
    /// Findings the owner chose to keep in the letter, by value, so the
    /// line does not come back on the next keystroke.
    @State private var keptInLetter: Set<String> = []
    /// The on-device review (LetterReview). Nil until asked for. An empty
    /// list is "nothing to ask", which is shown once and quietly.
    @State private var reviewGaps: [LetterReview.Gap]?
    @State private var reviewing = false
    @State private var dismissedGaps: Set<String> = []
    /// The letter card opens for writing when tapped, or from the start
    /// when there is no letter yet. Closed, it shows the first lines.
    @State private var writingLetter = false
    @State private var player: AVAudioPlayer?

    private var recipientName: String {
        if !envelope.isAddressed { return envelope.draftRecipientName ?? "them" }
        return friendStore.friends.first { $0.identity.credentialIDHash == envelope.recipientHash }?.identity.displayName ?? "them"
    }

    // MARK: - What the box holds

    private var hasLetter: Bool { !envelope.letter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var hasSteps: Bool { !envelope.usableFirstSteps.isEmpty }
    private var hasSecrets: Bool { !envelope.secrets.isEmpty }
    private var hasPhotos: Bool { !envelope.photos.isEmpty }
    private var hasVoice: Bool { envelope.voiceNote != nil }
    private var hasVideo: Bool { envelope.videoNote != nil }
    /// In Karen's order.
    private var filled: [Bool] { [hasLetter, hasVoice, hasVideo, hasPhotos, hasSteps, hasSecrets] }
    private static let dotNames = ["Letter", "Voice", "Video", "Photos", "Steps", "Secrets"]

    /// "A letter and 2 secrets. No voice, video, photos or steps yet."
    private var packingLine: String {
        var missing: [String] = []
        if !hasLetter { missing.append("letter") }
        if !hasVoice { missing.append("voice") }
        if !hasVideo { missing.append("video") }
        if !hasPhotos { missing.append("photos") }
        if !hasSteps { missing.append("steps") }
        if !hasSecrets { missing.append("secrets") }
        if missing.isEmpty { return "Everything is here. A letter, your voice, a video, photos, the steps and the secrets." }
        if missing.count == 6 { return "Empty so far. Start anywhere below." }
        let have = envelope.contentsSummary
        let haveLine = have.prefix(1).uppercased() + have.dropFirst() + "."
        let missingLine = missing.count == 1 ? missing[0] : missing.dropLast().joined(separator: ", ") + " or " + missing[missing.count - 1]
        return haveLine + " No " + missingLine + " yet."
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SealTheme.ink.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if !envelope.isAddressed { waitingForAPerson }
                        titleRow
                        packingCard
                        letterCard
                        voiceCard
                        videoCard
                        photosCard
                        stepsCard
                        secretsCard
                        if envelope.isAddressed { previewRow }
                        Text(envelope.isAddressed
                             ? "Written for \(recipientName). Opens on their phone, in the order you choose, only after your key holders release it."
                             : "Written for \(recipientName), who is not in Seal yet. Nothing about this envelope is published or sealed until you meet them and choose them above.")
                            .font(.caption).foregroundStyle(.white.opacity(0.45))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 4)
                        Button(role: .destructive) { confirmDelete = true } label: {
                            Text("Delete this envelope").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered).tint(.orange)
                        .parentTapTarget()
                    }
                    .padding(20)
                    .frame(maxWidth: 520)
                    .frame(maxWidth: .infinity)
                    .containerRelativeFrame(.horizontal)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle(envelope.title.isEmpty ? "Envelope" : envelope.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        estateEngine.updateEnvelope(envelope)
                        onClose()
                    }
                    .foregroundStyle(SealTheme.brass)
                }
            }
            .onAppear { writingLetter = !hasLetter }
            .task(id: envelope.videoNote?.blobID) { await loadVideoThumbnail() }
            .sheet(isPresented: $showVideo) {
                VideoRecorderPicker { data, problem in
                    showVideo = false
                    if let problem { self.error = problem }
                    guard let data else { return }
                    estateEngine.updateEnvelope(envelope)
                    do {
                        let item = try estateEngine.attachMedia(data, kind: .video, to: envelope.id)
                        envelope.videoNote = item
                    } catch { self.error = error.localizedDescription }
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showVideoPlayer) {
                if let video = envelope.videoNote, let data = estateEngine.mediaPlaintext(video, in: envelope) {
                    VideoPlaySheet(data: data, onClose: { showVideoPlayer = false })
                }
            }
            .sheet(isPresented: $showPreview) {
                // Save first, so the preview shows the letter as it is on
                // screen and not as it was when the editor opened.
                FamilyPreviewView(recipientHash: envelope.recipientHash, recipientName: recipientName,
                                  ownerName: ownerName, estateEngine: estateEngine,
                                  onClose: { showPreview = false })
                    .environment(\.parentMode, parentMode)
                    .parentTypeScale()
            }
            .sheet(isPresented: $showFirstSteps) {
                FirstStepsEditorSheet(steps: $envelope.firstSteps, secrets: $envelope.secrets,
                                      recipientName: recipientName,
                                      onAddSecret: { card in
                                          envelope.secrets.append(card)
                                          envelope.secretConfirmations[card.confirmationKey] = estateEngine.now
                                          return envelope.secrets.count - 1
                                      },
                                      onClose: { showFirstSteps = false })
                    .environment(\.parentMode, parentMode)
                    .parentTypeScale()
            }
            .sheet(isPresented: $showSecretEditor) {
                SecretEditorSheet { card in
                    showSecretEditor = false
                    if let card {
                        envelope.secrets.append(card)
                        // Adding is confirming (SecretReview).
                        envelope.secretConfirmations[card.confirmationKey] = estateEngine.now
                    }
                }
            }
            .sheet(isPresented: $showPhotoPicker) {
                SystemCameraPicker(source: .library) { image in
                    showPhotoPicker = false
                    guard let image, let data = image.jpegData(compressionQuality: 0.85) else { return }
                    estateEngine.updateEnvelope(envelope)
                    do {
                        let item = try estateEngine.attachMedia(data, kind: .photo, to: envelope.id)
                        envelope.photos.append(item)
                    } catch { self.error = error.localizedDescription }
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showVoice) {
                VoiceRecorderSheet { data in
                    showVoice = false
                    guard let data else { return }
                    estateEngine.updateEnvelope(envelope)
                    do {
                        let item = try estateEngine.attachMedia(data, kind: .voice, to: envelope.id)
                        envelope.voiceNote = item
                    } catch { self.error = error.localizedDescription }
                }
            }
            .confirmationDialog("Delete this envelope?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    estateEngine.removeEnvelope(envelope.id)
                    onClose()
                }
            } message: {
                Text("The letter and the secrets go with it. The people holding your keys are not told.")
            }
            .alert("Something went wrong", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - The top

    /// The one row at the top of an envelope that has words but no person.
    /// It states the good news first (the writing is safe here) because the
    /// person reading it just did the hard part and should not be met with a
    /// warning for it.
    private var waitingForAPerson: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.title3).foregroundStyle(.white.opacity(0.75))
                Text("This one is for \(recipientName), who is not in Seal yet.")
                    .font(.headline).foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Write as much as you like. It stays on this phone as a draft. When you meet \(recipientName) in person and add them under People, choose them here and this envelope becomes theirs.")
                .font(.callout).foregroundStyle(.white.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
            if let onChoosePerson {
                Button(action: onChoosePerson) {
                    Text("Choose the person").frame(maxWidth: .infinity)
                }
                .buttonStyle(SealSecondaryButtonStyle())
                .parentTapTarget(60)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
    }

    private var titleRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "envelope.fill").foregroundStyle(SealTheme.brass)
            TextField("For \(recipientName)", text: $envelope.title)
                .textFieldStyle(.plain)
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .foregroundStyle(.white)
        }
        .padding(14)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
    }

    /// One sentence and six dots. The dots are in Karen's order.
    private var packingCard: some View {
        let all = filled.allSatisfy { $0 }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(Array(Self.dotNames.enumerated()), id: \.offset) { i, name in
                    VStack(spacing: 4) {
                        Circle()
                            .fill(filled[i] ? SealTheme.brass : .white.opacity(0.08))
                            .overlay(Circle().strokeBorder(filled[i] ? SealTheme.brass : .white.opacity(0.25), lineWidth: 1))
                            .frame(width: 12, height: 12)
                        Text(name).font(.caption2).foregroundStyle(.white.opacity(filled[i] ? 0.8 : 0.4))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            Text(packingLine)
                .font(.callout).foregroundStyle(all ? SealTheme.brass : .white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
        .animation(.easeInOut(duration: 0.2), value: filled)
    }

    // MARK: - The six cards

    /// The shell every card uses: an icon, a title, what is in it or the
    /// invitation, and one action on the right.
    private func card<Content: View>(_ icon: String, _ title: String, filled: Bool,
                                     action: String, onAction: @escaping () -> Void,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(filled ? SealTheme.brass : .white.opacity(0.5))
                    .frame(width: 22)
                Text(title).font(.headline).foregroundStyle(.white)
                Spacer()
                Button(action: onAction) {
                    Text(action).font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered).tint(SealTheme.brass)
                .parentTapTarget(44)
            }
            content()
        }
        .padding(16)
        .background(.white.opacity(filled ? 0.06 : 0.035), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(filled ? SealTheme.brass.opacity(0.25) : .clear, lineWidth: 1))
    }

    private func invitation(_ line: String) -> some View {
        Text(line)
            .font(.callout).foregroundStyle(.white.opacity(0.55))
            .fixedSize(horizontal: false, vertical: true)
    }

    // The letter

    private var letterCard: some View {
        card("text.alignleft", "The letter", filled: hasLetter,
             action: writingLetter ? "Close" : (hasLetter ? "Write more" : "Write"),
             onAction: { withAnimation(.easeInOut(duration: 0.2)) { writingLetter.toggle() } }) {
            if writingLetter {
                TextEditor(text: $envelope.letter)
                    .scrollContentBackground(.hidden)
                    .font(.body).foregroundStyle(.white)
                    .frame(minHeight: 180)
                    .padding(10)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(alignment: .topLeading) {
                        if !hasLetter {
                            Text("Say what you would say if \(recipientName) were in the room.")
                                .foregroundStyle(.white.opacity(0.3)).padding(18).allowsHitTesting(false)
                        }
                    }
                if let finding = secretInLetter { secretInLetterLine(finding) }
                // The letter only. Deliberately NOT on the secrets,
                // where a password read aloud in a kitchen is a worse
                // idea than typing it. Secrets are typed, exactly as written.
                DictationButton(text: $envelope.letter)
                if LetterReview.isAvailable { reviewBlock }
            } else if hasLetter {
                Text(envelope.letter)
                    .font(.callout).foregroundStyle(.white.opacity(0.75))
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(envelope.letter.split(whereSeparator: \.isWhitespace).count) words")
                    .font(.caption).foregroundStyle(.white.opacity(0.4))
            } else {
                invitation("The part \(recipientName) will read first and keep longest. It does not have to be long.")
            }
        }
    }

    // What to do first

    private var stepsCard: some View {
        let steps = envelope.usableFirstSteps
        return card("list.number", "What to do first", filled: hasSteps,
                    action: hasSteps ? "Edit" : "Add",
                    onAction: { showFirstSteps = true }) {
            if hasSteps {
                StepsTimelineMini(steps: steps, secrets: envelope.secrets)
            } else {
                invitation("On a hard day a list is worth more than a pile of passwords. Who to call, where the will is, what to cancel.")
                HStack(spacing: 6) {
                    ForEach(FirstStep.starters.prefix(3)) { starter in
                        Text(starter.title)
                            .font(.caption).foregroundStyle(.white.opacity(0.6))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.white.opacity(0.06), in: Capsule())
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    // The secrets

    private var secretsCard: some View {
        card("lock.fill", "The secrets", filled: hasSecrets,
             action: "Add", onAction: { showSecretEditor = true }) {
            if hasSecrets {
                HStack {
                    Text(envelope.secrets.count == 1 ? "One secret, sealed exactly as written."
                                                     : "\(envelope.secrets.count) secrets, sealed exactly as written.")
                        .font(.caption).foregroundStyle(.white.opacity(0.5))
                    Spacer()
                    Button(revealSecrets ? "Hide" : "Show") {
                        if revealSecrets { revealSecrets = false; return }
                        Task {
                            if await AppLock.confirmSeal(ownerHash: estateEngine.ownerHash) { revealSecrets = true }
                        }
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(SealTheme.brass)
                    .parentTapTarget(40)
                }
                ForEach(Array(envelope.secrets.enumerated()), id: \.offset) { index, card in
                    secretRow(index: index, card: card)
                }
            } else {
                invitation("Passwords, where the safe deposit key is, the combination, the seed phrase. This is the part people buy this for.")
            }
        }
    }

    private func secretRow(index: Int, card: SealedCard) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "key.fill").foregroundStyle(SealTheme.brass.opacity(0.8)).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(card.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                Text(card.typeLine).font(.caption2).foregroundStyle(.white.opacity(0.5))
                // How long since the owner said this one is still right.
                Text(SecretAge.line(since: envelope.confirmedAt(card), now: estateEngine.now))
                    .font(.caption2).foregroundStyle(.white.opacity(0.4))
                if revealSecrets {
                    Text(card.displayValue)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(String(repeating: "\u{2022}", count: min(card.value.count, 24)))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
            Spacer()
            // Through the model, so a step that pointed at this secret
            // loses its link instead of pointing at the wrong one.
            Button(role: .destructive) { envelope.removeSecret(at: index) } label: {
                Image(systemName: "trash").foregroundStyle(.orange.opacity(0.8))
            }
            .parentTapTarget()
        }
        .padding(12)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }

    // Photos

    private var photosCard: some View {
        card("photo.on.rectangle", "Photos", filled: hasPhotos,
             action: "Add", onAction: { showPhotoPicker = true }) {
            if hasPhotos {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(envelope.photos) { item in
                            ZStack(alignment: .topTrailing) {
                                if let data = estateEngine.mediaPlaintext(item, in: envelope), let image = UIImage(data: data) {
                                    Image(uiImage: image).resizable().scaledToFill()
                                        .frame(width: 96, height: 96).clipShape(RoundedRectangle(cornerRadius: 12))
                                } else {
                                    RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.08)).frame(width: 96, height: 96)
                                }
                                Button { envelope.photos.removeAll { $0.blobID == item.blobID } } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black.opacity(0.6))
                                }
                                .padding(4)
                            }
                        }
                    }
                }
            } else {
                invitation("A picture of the two of you. The house. The dog. \(recipientName) will look at it more than once.")
            }
        }
    }

    // Voice

    private var voiceCard: some View {
        card("waveform", "Your voice", filled: hasVoice,
             action: hasVoice ? "Record again" : "Record", onAction: { showVoice = true }) {
            if let voice = envelope.voiceNote {
                HStack(spacing: 12) {
                    Button {
                        play(voice)
                    } label: {
                        Image(systemName: player?.isPlaying == true ? "stop.circle.fill" : "play.circle.fill")
                            .font(.system(size: 34)).foregroundStyle(SealTheme.brass)
                    }
                    .parentTapTarget(48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Voice message").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(voice.byteCount), countStyle: .file))
                            .font(.caption).foregroundStyle(.white.opacity(0.5))
                    }
                    Spacer()
                    Button(role: .destructive) { envelope.voiceNote = nil } label: {
                        Image(systemName: "trash").foregroundStyle(.orange.opacity(0.8))
                    }
                    .parentTapTarget()
                }
            } else {
                invitation("Thirty seconds is enough. \(recipientName) will want to hear you say their name.")
            }
        }
    }

    // Video

    private var videoCard: some View {
        card("video.fill", "A video", filled: hasVideo,
             action: hasVideo ? "Record again" : "Record", onAction: { showVideo = true }) {
            if let video = envelope.videoNote {
                HStack(spacing: 12) {
                    Button { showVideoPlayer = true } label: {
                        ZStack {
                            if let thumb = videoThumbnail {
                                Image(uiImage: thumb).resizable().scaledToFill()
                            } else {
                                Rectangle().fill(.white.opacity(0.08))
                            }
                            Image(systemName: "play.fill").font(.title2).foregroundStyle(.white)
                                .shadow(radius: 4)
                        }
                        .frame(width: 96, height: 96).clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .parentTapTarget(96)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Video message").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(video.byteCount), countStyle: .file))
                            .font(.caption).foregroundStyle(.white.opacity(0.5))
                        Text("Tap to watch").font(.caption).foregroundStyle(SealTheme.brass.opacity(0.8))
                    }
                    Spacer()
                    Button(role: .destructive) { envelope.videoNote = nil } label: {
                        Image(systemName: "trash").foregroundStyle(.orange.opacity(0.8))
                    }
                    .parentTapTarget()
                }
            } else {
                invitation("Up to a minute, from the front camera. Your face, your voice, in your kitchen. Nothing else in the envelope will be looked at more.")
            }
        }
    }

    /// The first frame, for the card. Read from the owner's local copy.
    private func loadVideoThumbnail() async {
        videoThumbnail = nil
        guard let video = envelope.videoNote, let data = estateEngine.mediaPlaintext(video, in: envelope),
              let url = try? MediaSaving.tempFile(data, extension: "mov", name: "thumb-\(video.blobID)") else { return }
        defer { try? FileManager.default.removeItem(at: url) }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        if let result = try? await generator.image(at: .init(seconds: 0.5, preferredTimescale: 600)) {
            videoThumbnail = UIImage(cgImage: result.image)
        }
    }

    private func play(_ item: MediaItem) {
        if let p = player, p.isPlaying { p.stop(); player = nil; return }
        guard let data = estateEngine.mediaPlaintext(item, in: envelope) else {
            error = "That recording is not on this phone."; return
        }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
            let p = try AVAudioPlayer(data: data)
            p.play()
            player = p
        } catch { self.error = error.localizedDescription }
    }

    // MARK: - What they see

    /// The door to the preview. Saves the envelope on the way so what is
    /// shown is what is on screen. Not brass: looking is not a trust moment.
    private var previewRow: some View {
        Button {
            estateEngine.updateEnvelope(envelope)
            showPreview = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "eye").font(.title3).foregroundStyle(.white.opacity(0.7)).frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text("See it as \(recipientName) sees it")
                        .font(.headline).foregroundStyle(.white)
                    Text("Their screen, with everything you have written for them, in order.")
                        .font(.caption).foregroundStyle(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.white.opacity(0.3))
            }
            .padding(16)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .parentTapTarget()
    }

    // MARK: - Would this help them?

    /// A soft, dismissible list, never a blocker. The button only exists on
    /// a phone with the on-device model; every other phone never sees this
    /// block. Nothing here edits the letter: it asks, the owner answers by
    /// typing into the letter above, or ignores it.
    private var reviewBlock: some View {
        let shown = (reviewGaps ?? []).filter { !dismissedGaps.contains($0.id) }
        return VStack(alignment: .leading, spacing: 10) {
            if let gaps = reviewGaps, !gaps.isEmpty, shown.isEmpty {
                // Every question answered or waved away. Say nothing more.
                EmptyView()
            } else if let gaps = reviewGaps, gaps.isEmpty {
                Text("Nothing \(recipientName) could not act on. The letter reads clearly.")
                    .font(.callout).foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            } else if !shown.isEmpty {
                Text("Things \(recipientName) might not be able to act on. Your words, your call. Answer in the letter, or wave a question away.")
                    .font(.callout).foregroundStyle(.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(shown) { gap in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\u{201C}\(gap.quote)\u{201D}")
                                .font(.callout.italic()).foregroundStyle(.white.opacity(0.55))
                            Text(gap.question)
                                .font(.callout).foregroundStyle(.white)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button { dismissedGaps.insert(gap.id) } label: {
                            Image(systemName: "xmark").font(.caption.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        .accessibilityLabel("Wave this question away")
                        .parentTapTarget()
                    }
                    .padding(12)
                    .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            Button {
                runReview()
            } label: {
                HStack {
                    if reviewing { ProgressView().tint(.white) }
                    Label(reviewGaps == nil ? "Check the letter for gaps" : "Check the letter again",
                          systemImage: "text.magnifyingglass")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(SealSecondaryButtonStyle())
            .disabled(reviewing || envelope.letter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .parentTapTarget()
            Text("Read on this phone only. It looks for a folder with no name, a person with no number, a place with no address. It never sees the secrets and never changes a word.")
                .font(.caption).foregroundStyle(.white.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
    }

    private func runReview() {
        guard !reviewing else { return }
        reviewing = true
        dismissedGaps = []
        // Material can only be built from the letter (LetterReview.Material).
        let material = LetterReview.Material(envelope: envelope, recipientName: recipientName)
        Task {
            defer { reviewing = false }
            // A nil result is a helper that did not help. Leave the last
            // list alone rather than replacing it with an error.
            if let gaps = await LetterReview.review(material) { reviewGaps = gaps }
        }
    }

    // MARK: - A secret typed into the letter

    /// The first thing in the letter that looks like a recovery phrase or a
    /// private key, and that the owner has not already said to keep. Plain
    /// string matching on the phone (LetterSecretScan); nothing is sent
    /// anywhere and nothing is changed without a tap.
    private var secretInLetter: LetterSecretScan.Finding? {
        LetterSecretScan.scan(envelope.letter).first { !keptInLetter.contains($0.id) }
    }

    /// One quiet line and two small buttons. Not a warning colour, not a
    /// blocker, and it is gone the moment the owner answers either way.
    private func secretInLetterLine(_ finding: LetterSecretScan.Finding) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(finding.line)
                .font(.callout).foregroundStyle(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button {
                    moveIntoSecret(finding)
                } label: {
                    Label("Move it to a secret", systemImage: "lock.fill")
                }
                .buttonStyle(.bordered).tint(SealTheme.brass)
                .parentTapTarget()
                Button("Keep it in the letter") { keptInLetter.insert(finding.id) }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.5))
                    .parentTapTarget()
            }
        }
        .padding(.horizontal, 4)
    }

    /// The same path a typed secret takes (SealedCard.validated), so the
    /// moved value obeys the same rules as one entered by hand. The letter
    /// loses exactly the matched text and nothing else.
    private func moveIntoSecret(_ finding: LetterSecretScan.Finding) {
        do {
            let card = try SealedCard.validated(cardType: finding.cardType, title: finding.cardTitle, value: finding.value)
            envelope.secrets.append(card)
            envelope.secretConfirmations[card.confirmationKey] = estateEngine.now
            envelope.letter = LetterSecretScan.removing(finding, from: envelope.letter)
        } catch {
            self.error = error.localizedDescription
        }
    }

}

// MARK: - A secret

struct SecretEditorSheet: View {
    let onDone: (SealedCard?) -> Void
    @State private var type: SealedCardType = .password
    @State private var title = ""
    @State private var value = ""
    @State private var note = ""
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            ZStack {
                SealTheme.ink.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Picker("What kind", selection: $type) {
                            ForEach(SealedCardType.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.menu).tint(SealTheme.brass)
                        TextField("What is it called", text: $title)
                            .padding(14).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
                        TextEditor(text: $value)
                            .scrollContentBackground(.hidden)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 120)
                            .padding(10).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
                            .overlay(alignment: .topLeading) {
                                if value.isEmpty {
                                    Text(type.valuePlaceholder).foregroundStyle(.white.opacity(0.3)).padding(18).allowsHitTesting(false)
                                }
                            }
                        TextField("A note for them (optional)", text: $note)
                            .padding(14).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
                        Text("Sealed exactly as written. Seal never fixes, trims or checks a secret, because a secret that has been \"corrected\" is worse than none.")
                            .font(.caption).foregroundStyle(.white.opacity(0.45))
                            .fixedSize(horizontal: false, vertical: true)
                        if let problem {
                            Text(problem).font(.callout).foregroundStyle(.orange)
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(20)
                }
            }
            .navigationTitle("A secret")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onDone(nil) }.foregroundStyle(SealTheme.brass) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        do {
                            onDone(try SealedCard.validated(cardType: type, title: title, value: value, note: note))
                        } catch {
                            problem = error.localizedDescription
                        }
                    }
                    .foregroundStyle(SealTheme.brass)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Voice

/// One button. Tap to start, tap to stop. AAC in an m4a container, which
/// every Apple device in 2050 will still play.
struct VoiceRecorderSheet: View {
    let onDone: (Data?) -> Void
    @State private var recorder: AVAudioRecorder?
    @State private var recording = false
    @State private var seconds = 0
    @State private var problem: String?
    @State private var url = FileManager.default.temporaryDirectory.appendingPathComponent("seal-voice-\(UUID().uuidString).m4a")

    var body: some View {
        NavigationStack {
            ZStack {
                SealTheme.ink.ignoresSafeArea()
                ScrollView {
                VStack(spacing: 24) {
                    Text(recording ? "Recording" : "Ready")
                        .font(.system(.title2, design: .rounded, weight: .semibold)).foregroundStyle(.white)
                    Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                        .font(.system(size: 44, design: .monospaced)).foregroundStyle(SealTheme.brass)
                    Button {
                        recording ? stop() : start()
                    } label: {
                        Image(systemName: recording ? "stop.circle.fill" : "record.circle")
                            .font(.system(size: 88)).foregroundStyle(recording ? .orange : SealTheme.brass)
                    }
                    .parentTapTarget(96)
                    Text(recording ? "Tap to stop." : "Tap to start. Say what you would say if they were in the room.")
                        .font(.callout).foregroundStyle(.white.opacity(0.55)).multilineTextAlignment(.center).padding(.horizontal, 32)
                    if let problem { Text(problem).foregroundStyle(.orange).font(.callout) }
                }
                .padding(.vertical, 32)
                .frame(maxWidth: .infinity)
                .containerRelativeFrame(.horizontal)
                }
            }
            .navigationTitle("Voice message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { recorder?.stop(); onDone(nil) }.foregroundStyle(SealTheme.brass)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use it") {
                        if recording { stop() }
                        onDone(try? Data(contentsOf: url))
                    }
                    .foregroundStyle(SealTheme.brass)
                    .disabled(recording || seconds == 0)
                }
            }
            .task(id: recording) {
                while recording {
                    try? await Task.sleep(for: .seconds(1))
                    if recording { seconds += 1 }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func start() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default)
            try session.setActive(true)
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.record()
            recorder = r
            seconds = 0
            recording = true
        } catch {
            problem = "Could not start recording. Check the microphone permission in Settings."
        }
    }

    private func stop() {
        recorder?.stop()
        recording = false
    }
}
