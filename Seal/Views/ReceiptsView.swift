import SwiftUI
import UIKit
import CryptoKit
import os

//  ReceiptsView.swift
//  Seal
//
//  The custody ledger: every handover this identity has signed or received.
//  See CustodyReceipt.swift for what a receipt actually proves (and what it
//  deliberately does not).

struct ReceiptsView: View {
    let myRoot: RootIdentity
    @Bindable var identity: IdentityManager
    @Bindable var ceremony: CeremonyManager
    let sync: SyncEngine

    @State private var store: ReceiptStore
    @State private var showNew = false

    init(myRoot: RootIdentity, identity: IdentityManager,
         ceremony: CeremonyManager, sync: SyncEngine) {
        self.myRoot = myRoot
        self.identity = identity
        self.ceremony = ceremony
        self.sync = sync
        _store = State(initialValue: ReceiptStore(ownerHash: myRoot.credentialIDHash))
    }

    var body: some View {
        ZStack {
            SealTheme.ink.ignoresSafeArea()
            if store.receipts.isEmpty {
                VStack(spacing: 14) {
                    SealMascot(size: 52,
                               line: "No handovers yet.",
                               sub: "A receipt proves you handed something over, in person, and they took it.")
                }
                .padding(.horizontal, 32)
            } else {
                List {
                    ForEach(store.sorted) { receipt in
                        NavigationLink {
                            ReceiptDetailView(receipt: receipt, myRoot: myRoot,
                                              identity: identity, sync: sync)
                        } label: {
                            row(receipt)
                        }
                        .listRowBackground(Color.white.opacity(0.04))
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Handovers")
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showNew = true } label: {
                    Image(systemName: "plus.circle.fill").foregroundStyle(SealTheme.brass)
                }
            }
        }
        .sheet(isPresented: $showNew) {
            NewReceiptView(myRoot: myRoot, identity: identity, ceremony: ceremony,
                           sync: sync, store: store)
        }
        .task {
            // Read the keychain HERE, not in ReceiptStore.init — SwiftUI
            // evaluates a NavigationLink's destination on every parent body
            // pass, so an init that touched the keychain would do so on every
            // chat update.
            store.loadIfNeeded()
            // Receipts issued TO us arrive the same way forge handshakes do.
            // NOTE: this is the only place that runs, so a receipt lands when
            // the recipient opens Handovers — not on push. Fine for v1.
            await ReceiptService.check(myRoot: myRoot, identity: identity,
                                       store: store, sync: sync)
        }
    }

    private func row(_ receipt: CustodyReceipt) -> some View {
        let iGave = receipt.giverHash == myRoot.credentialIDHash
        return HStack(spacing: 12) {
            Image(systemName: iGave ? "arrow.up.right.circle.fill" : "arrow.down.left.circle.fill")
                .foregroundStyle(iGave ? SealTheme.brass : SealTheme.silver)
            VStack(alignment: .leading, spacing: 2) {
                Text(receipt.itemDescription)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("\(iGave ? "to" : "from") \(iGave ? receipt.receiverName : receipt.giverName) · \(receipt.signedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }
}

// MARK: - Detail

struct ReceiptDetailView: View {
    let receipt: CustodyReceipt
    let myRoot: RootIdentity
    @Bindable var identity: IdentityManager
    let sync: SyncEngine

    @State private var verdict: CustodyReceipt.Verdict?
    @State private var photo: UIImage?
    @State private var shareCard: Image?

    var body: some View {
        ZStack {
            SealTheme.ink.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 18) {
                    if let photo {
                        Image(uiImage: photo)
                            .resizable().scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .padding(.horizontal, 20)
                    }

                    Text(receipt.itemDescription)
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)

                    // Re-verified live, every time this opens. A receipt that
                    // only claims to be valid is worthless; this actually
                    // recomputes the commitment and checks both signatures
                    // against the public directory.
                    verdictBadge

                    party("Handed over by", receipt.giverName, receipt.giverHash)
                    party("Received by", receipt.receiverName, receipt.receiverHash)

                    detail("Signed", receipt.signedAt.formatted(date: .long, time: .standard))
                    if receipt.photoSHA256 != nil {
                        detail("Photo fingerprint", shortHash(receipt.photoSHA256))
                    }
                    detail("Receipt", String(receipt.receiptID.prefix(8)))

                    // Only exportable once it verifies. A shareable artifact
                    // that says "signed by both parties' hardware keys" must
                    // never be produced for a receipt we couldn't check.
                    if let shareCard, verdict?.isValid == true {
                        ShareLink(item: shareCard,
                                  preview: SharePreview("Seal handover receipt", image: shareCard)) {
                            Label("Share receipt", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity).padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(SealTheme.brass)
                        .padding(.horizontal, 24)
                    }
                }
                .padding(.vertical, 20)
            }
        }
        .navigationTitle("Receipt")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { await load() }
    }

    private var verdictBadge: some View {
        Group {
            switch verdict {
            case .valid:
                label("Both signatures verified", "checkmark.seal.fill", SealTheme.brass)
            case .receiverSignatureFailed:
                label("Receiver's signature doesn't match", "xmark.seal.fill", .orange)
            case .giverSignatureFailed:
                label("Issuer's signature doesn't match", "xmark.seal.fill", .orange)
            case .photoAltered:
                label("The photo has changed since signing", "exclamationmark.triangle.fill", .orange)
            case .identityMissing:
                label("Couldn't reach the directory to verify", "wifi.slash", .gray)
            case nil:
                ProgressView().tint(SealTheme.brass)
            }
        }
    }

    private func label(_ text: String, _ icon: String, _ tint: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.footnote.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(tint.opacity(0.12), in: Capsule())
    }

    private func party(_ role: String, _ name: String, _ hash: String) -> some View {
        VStack(spacing: 3) {
            Text(role).font(.caption2).foregroundStyle(.white.opacity(0.45))
            Text(name).font(.callout.weight(.medium)).foregroundStyle(.white)
            // The name is mutable metadata; the fingerprint phrase is derived
            // from the key, so THIS is the part that identifies them.
            Text(String(hash.prefix(12)))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.white.opacity(0.35))
        }
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.white.opacity(0.45))
            Spacer()
            Text(value).font(.caption).foregroundStyle(.white.opacity(0.75))
        }
        .padding(.horizontal, 28)
    }

    private func shortHash(_ data: Data?) -> String {
        (data ?? Data()).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    @MainActor
    private func load() async {
        // Keep the ORIGINAL bytes. Rendering to UIImage and re-encoding with
        // jpegData() produces a different byte stream (JPEG re-encoding is
        // lossy and not idempotent), so hashing that would report "photo
        // altered" on every honest receipt — including both phones in a demo.
        var originalPhotoBytes: Data?
        if let ref = receipt.mediaRef, let key = receipt.mediaKey,
           let blob = try? await sync.fetchMediaAsset(ref),
           let box = try? AES.GCM.SealedBox(combined: blob),
           let jpeg = try? AES.GCM.open(box, using: SymmetricKey(data: key)) {
            originalPhotoBytes = jpeg
            photo = UIImage(data: jpeg)
        }
        var directory: [String: (RootIdentity, [DeviceEndorsement])] = [:]
        for hash in [receipt.giverHash, receipt.receiverHash] {
            if let entry = try? await sync.fetchIdentity(credentialIDHash: hash) {
                directory[hash] = entry
            }
        }
        verdict = receipt.verify(against: directory,
                                 photo: originalPhotoBytes,
                                 using: identity)
        renderCard()
    }

    @MainActor
    private func renderCard() {
        guard verdict?.isValid == true else { shareCard = nil; return }
        let renderer = ImageRenderer(content: ReceiptCard(receipt: receipt, verified: true))
        renderer.scale = 3
        if let ui = renderer.uiImage { shareCard = Image(uiImage: ui) }
    }
}

/// The shareable proof. Fixed-size and self-contained — ImageRenderer draws it
/// offscreen, so nothing here may depend on the surrounding layout.
struct ReceiptCard: View {
    let receipt: CustodyReceipt
    let verified: Bool

    var body: some View {
        VStack(spacing: 0) {
            SealFigure(detailed: true, animated: false, tint: SealTheme.brass)
                .frame(width: 96, height: 60)
                .padding(.top, 30)

            Text("HANDOVER RECEIPT")
                .font(.system(.caption2, design: .rounded, weight: .bold))
                .tracking(2)
                .foregroundStyle(.white.opacity(0.5))
                .padding(.top, 14)

            Text(receipt.itemDescription)
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 26)
                .padding(.top, 8)

            VStack(spacing: 6) {
                Text(receipt.giverName)
                    .font(.system(.footnote, design: .rounded, weight: .semibold))
                    .foregroundStyle(SealTheme.brass)
                Image(systemName: "arrow.down")
                    .font(.caption2).foregroundStyle(.white.opacity(0.35))
                Text(receipt.receiverName)
                    .font(.system(.footnote, design: .rounded, weight: .semibold))
                    .foregroundStyle(SealTheme.brass)
            }
            .padding(.top, 18)

            Text(receipt.signedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.45))
                .padding(.top, 14)

            if verified {
                Label("Both keys verified in person", systemImage: "checkmark.seal.fill")
                    .font(.system(.caption2, design: .rounded, weight: .medium))
                    .foregroundStyle(SealTheme.brass)
                    .padding(.top, 10)
            }

            Spacer()

            Text("Signed by both parties' hardware keys · sealmessenger.com")
                .font(.system(size: 8))
                .foregroundStyle(.white.opacity(0.35))
                .padding(.bottom, 22)
        }
        .frame(width: 340, height: 460)
        .background(SealTheme.ink)
    }
}

// MARK: - Issue a new receipt

struct NewReceiptView: View {
    let myRoot: RootIdentity
    @Bindable var identity: IdentityManager
    @Bindable var ceremony: CeremonyManager
    let sync: SyncEngine
    @Bindable var store: ReceiptStore

    @Environment(\.dismiss) private var dismiss

    private enum Step: Equatable {
        case describe
        case capture
        case scan
        case lookingUp
        case confirm(RootIdentity)
        case signing(RootIdentity)
        case done
        case failed(String)
    }
    @State private var step: Step = .describe
    @State private var item = ""
    @State private var photo: UIImage?

    var body: some View {
        NavigationStack {
            ZStack {
                SealTheme.ink.ignoresSafeArea()
                switch step {
                case .describe: describeStep
                case .capture: captureStep
                case .scan: scanStep
                case .lookingUp: progress("Looking them up…")
                case .confirm(let who): confirmStep(who)
                case .signing(let who): progress("Waiting for \(who.displayName)'s key…")
                case .done: doneStep
                case .failed(let why): failedStep(why)
                }
            }
            .navigationTitle("New handover")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var describeStep: some View {
        VStack(spacing: 18) {
            Text("What are you handing over?")
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .foregroundStyle(.white)
            TextField("MacBook Pro 14\", serial C02X…", text: $item, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .padding(14)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
            Text("Be specific. This exact text is signed by both of you — one character different and the signatures no longer match.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .padding(.top, 24)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 6) {
                Button { step = .capture } label: {
                    Label("Take a photo", systemImage: "camera.fill")
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent).tint(SealTheme.brass)
                .disabled(item.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Skip the photo") { step = .scan }
                    .foregroundStyle(.white.opacity(0.6))
                    .disabled(item.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 24).padding(.top, 10).padding(.bottom, 6)
        }
    }

    private var captureStep: some View {
        VStack(spacing: 14) {
            SystemCameraPicker(source: .camera) { image in
                if let image {
                    photo = image
                    step = .scan
                } else {
                    step = .describe
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .frame(minHeight: 200)
            .padding(.horizontal, 20)
            Text("Photograph the item as you hand it over. Its fingerprint is signed into the receipt.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .padding(.top, 12)
    }

    private var scanStep: some View {
        VStack(spacing: 14) {
            Text("Scan their seal")
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .foregroundStyle(.white)
            QRScannerView { code in
                guard code.hasPrefix("seal:") else { return }
                let hash = String(code.dropFirst(5))
                step = .lookingUp
                Task { await lookup(hash) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .frame(minHeight: 200)
            .padding(.horizontal, 24)
            Text("They don't have to be a friend — a receipt is its own ceremony.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.45))
                .padding(.horizontal, 32)
        }
        .padding(.top, 12)
    }

    private func confirmStep(_ who: RootIdentity) -> some View {
        VStack(spacing: 16) {
            if let photo {
                Image(uiImage: photo).resizable().scaledToFit()
                    .frame(maxHeight: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            Text(item)
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            RoleBanner(icon: "key.radiowaves.forward.fill",
                       text: "Hand this phone to \(who.displayName). When they tap their key, they're signing that they received this exact item — it can't be produced without them.")
            Spacer()
        }
        .padding(.top, 16)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 6) {
                Button { Task { await sign(with: who) } } label: {
                    Label("\(who.displayName) taps their key", systemImage: "key.radiowaves.forward.fill")
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent).tint(SealTheme.brass)
                Button("Back") { step = .scan }.foregroundStyle(.white.opacity(0.6))
            }
            .padding(.horizontal, 24).padding(.top, 10).padding(.bottom, 6)
        }
    }

    private var doneStep: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 72)).foregroundStyle(SealTheme.brass)
            Text("Receipt sealed")
                .font(.system(.title2, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
            Text("Both keys signed it. Neither of you can deny this handover, and anyone can verify it.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            Spacer()
        }
        .safeAreaInset(edge: .bottom) {
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent).tint(SealTheme.brass)
                .padding(.top, 10).padding(.bottom, 6)
        }
    }

    private func failedStep(_ why: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "xmark.seal.fill").font(.system(size: 56)).foregroundStyle(.orange)
            Text(why)
                .font(.callout).foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center).padding(.horizontal, 32)
            Spacer()
        }
        .safeAreaInset(edge: .bottom) {
            Button("Try again") { step = .scan }
                .buttonStyle(.borderedProminent).tint(SealTheme.brass)
                .padding(.top, 10).padding(.bottom, 6)
        }
    }

    private func progress(_ text: String) -> some View {
        VStack(spacing: 16) {
            ProgressView().tint(SealTheme.brass).scaleEffect(1.4)
            Text(text).font(.callout).foregroundStyle(.white.opacity(0.7))
        }
    }

    // MARK: - Actions

    @MainActor
    private func lookup(_ hash: String) async {
        guard hash != myRoot.credentialIDHash else {
            step = .failed("That's your own seal — a receipt needs two people."); return
        }
        do {
            guard let (who, _) = try await sync.fetchIdentity(credentialIDHash: hash) else {
                step = .failed("Nobody in the directory with that seal."); return
            }
            step = .confirm(who)
        } catch {
            step = .failed("Couldn't reach the directory: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func sign(with who: RootIdentity) async {
        step = .signing(who)
        ceremony.resetPhase()
        let jpeg = photo?.jpegData(compressionQuality: 0.9)
        do {
            var receipt = try await ReceiptService.issue(
                item: item.trimmingCharacters(in: .whitespacesAndNewlines),
                photo: jpeg, to: who, from: myRoot,
                identity: identity, ceremony: ceremony)

            // Delivery is best-effort: the receipt is already fully signed and
            // valid on THIS device, so a directory hiccup must not throw away
            // evidence we just collected in person.
            if let entry = try? await sync.fetchIdentity(credentialIDHash: who.credentialIDHash) {
                let endorsements = IdentityManager.verifiedDevices(root: entry.0,
                                                                   endorsements: entry.1)
                if let delivered = try? await ReceiptService.publish(
                    receipt, photo: jpeg,
                    receiverEndorsements: endorsements, sync: sync) {
                    receipt = delivered
                } else {
                    ReceiptService.log.error("sign: couldn't deliver their copy — ours is still valid")
                }
            }
            store.add(receipt)
            step = .done
        } catch {
            step = .failed((error as? LocalizedError)?.errorDescription
                           ?? "The receipt wasn't signed. Nothing was recorded.")
        }
    }
}
