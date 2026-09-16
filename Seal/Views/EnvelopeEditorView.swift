// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import AVFoundation

//  EnvelopeEditorView.swift
//  Seal
//
//  WRITE AN ENVELOPE. A letter, a few photos, a voice message, and the
//  secrets. Every edit un-seals the envelope; the home screen's Seal button
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
    @State private var confirmDelete = false
    @State private var showPreview = false
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

    private var recipientName: String {
        if !envelope.isAddressed { return envelope.draftRecipientName ?? "them" }
        return friendStore.friends.first { $0.identity.credentialIDHash == envelope.recipientHash }?.identity.displayName ?? "them"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SealTheme.ink.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if !envelope.isAddressed { waitingForAPerson }
                        field("Title") {
                            TextField("For \(recipientName)", text: $envelope.title)
                                .textFieldStyle(.plain)
                        }
                        field("The letter") {
                            TextEditor(text: $envelope.letter)
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 160)
                        }
                        if let finding = secretInLetter { secretInLetterLine(finding) }
                        // The letter only. Deliberately NOT on the secrets,
                        // where a password read aloud in a kitchen is a worse
                        // idea than typing it, and where a transcriber that
                        // hears "capital B, one, ampersand" and writes
                        // something close is a secret that quietly stops
                        // working. Secrets are typed, exactly as written.
                        DictationButton(text: $envelope.letter)
                        if LetterReview.isAvailable { reviewBlock }
                        secretsBlock
                        mediaBlock
                        if envelope.isAddressed { previewRow }
                        Text(envelope.isAddressed
                             ? "Written for \(recipientName). Opens on their phone, in the order you choose, only after your custodians release it."
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
            }
            .navigationTitle("Envelope")
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
            .sheet(isPresented: $showPreview) {
                // Save first, so the preview shows the letter as it is on
                // screen and not as it was when the editor opened.
                FamilyPreviewView(recipientHash: envelope.recipientHash, recipientName: recipientName,
                                  ownerName: ownerName, estateEngine: estateEngine,
                                  onClose: { showPreview = false })
                    .environment(\.parentMode, parentMode)
                    .parentTypeScale()
            }
            .sheet(isPresented: $showSecretEditor) {
                SecretEditorSheet { card in
                    showSecretEditor = false
                    if let card { envelope.secrets.append(card) }
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

    // MARK: - Secrets

    private var secretsBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("The secrets").font(.headline).foregroundStyle(.white)
                Spacer()
                if !envelope.secrets.isEmpty {
                    Button(revealSecrets ? "Hide" : "Show") {
                        if revealSecrets { revealSecrets = false; return }
                        Task {
                            if await AppLock.confirmSeal(ownerHash: estateEngine.ownerHash) { revealSecrets = true }
                        }
                    }
                    .font(.caption).foregroundStyle(SealTheme.brass)
                }
                Button { showSecretEditor = true } label: { Label("Add", systemImage: "plus") }
                    .buttonStyle(.bordered).tint(SealTheme.brass)
                    .parentTapTarget()
            }
            if envelope.secrets.isEmpty {
                Text("Passwords, where the safe deposit key is, the combination, the seed phrase. This is the part people buy this for.")
                    .font(.callout).foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(envelope.secrets.enumerated()), id: \.offset) { index, card in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "lock.fill").foregroundStyle(SealTheme.brass).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(card.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        Text(card.typeLine).font(.caption2).foregroundStyle(.white.opacity(0.5))
                        if revealSecrets {
                            Text(card.displayValue)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.9))
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text(String(repeating: "•", count: min(card.value.count, 24)))
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.35))
                        }
                    }
                    Spacer()
                    Button(role: .destructive) { envelope.secrets.remove(at: index) } label: {
                        Image(systemName: "trash").foregroundStyle(.orange.opacity(0.8))
                    }
                    .parentTapTarget()
                }
                .padding(14)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    // MARK: - Media

    private var mediaBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Photos and a voice message").font(.headline).foregroundStyle(.white)
            HStack(spacing: 10) {
                Button { showPhotoPicker = true } label: { Label("Add a photo", systemImage: "photo") }
                    .buttonStyle(.bordered).tint(SealTheme.brass)
                    .parentTapTarget()
                Button { showVoice = true } label: {
                    Label(envelope.voiceNote == nil ? "Record a message" : "Record again", systemImage: "mic.fill")
                }
                .buttonStyle(.bordered).tint(SealTheme.brass)
                .parentTapTarget()
            }
            if !envelope.photos.isEmpty {
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
            }
            if let voice = envelope.voiceNote {
                HStack {
                    Image(systemName: "waveform").foregroundStyle(SealTheme.brass)
                    Text("Voice message, \(ByteCountFormatter.string(fromByteCount: Int64(voice.byteCount), countStyle: .file))")
                        .font(.callout).foregroundStyle(.white.opacity(0.8))
                    Spacer()
                    Button(role: .destructive) { envelope.voiceNote = nil } label: {
                        Image(systemName: "trash").foregroundStyle(.orange.opacity(0.8))
                    }
                    .parentTapTarget()
                }
                .padding(14)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
            }
        }
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
                    Label(reviewGaps == nil ? "Would this help \(recipientName)?" : "Check the letter again",
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
            envelope.letter = LetterSecretScan.removing(finding, from: envelope.letter)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func field<T: View>(_ label: String, @ViewBuilder content: () -> T) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.headline).foregroundStyle(.white)
            content()
                .font(.body)
                .foregroundStyle(.white)
                .padding(14)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
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
