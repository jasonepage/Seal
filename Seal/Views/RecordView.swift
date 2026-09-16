import SwiftUI

/// The Record (docs/RECORD.md), phase 1.
///
/// One timeline for everything Seal can account for. Until now the same four
/// kinds of evidence lived on four separate screens and nothing presented them
/// as one thing, which is most of why the product was hard to describe.
///
/// A record is a security surface, so **no mascot here** (UI.md §1.1) and no
/// reassuring language. The footer says plainly what these lines prove and
/// what they do not, because a record whose limits are unstated is worse than
/// no record at all: somebody will lean on it in an argument.
struct RecordView: View {
    let myRoot: RootIdentity
    @Bindable var friendStore: FriendStore
    let estateEngine: EstateEngine
    /// Set for one person's timeline. nil shows everything.
    var counterpart: FriendStore.StoredFriend? = nil
    /// Set when presented as a sheet rather than pushed.
    var onClose: (() -> Void)? = nil

    @State private var receipts: [CustodyReceipt] = []
    @State private var tokens: [String: TimestampRecord] = [:]
    @State private var timestampsOn = false
    @State private var receiptsFailed = false

    /// Recomputed per body pass on purpose. It is a projection over stores that
    /// are already in memory (RecordEvent.swift), so caching it would introduce
    /// the exact second-source-of-truth this design refuses. The digests are a
    /// SHA-256 each over a few dozen bytes; measure before this matters.
    private var events: [RecordEvent] {
        RecordBuilder.events(myRoot: myRoot,
                             friendStore: friendStore,
                             receipts: receipts,
                             estateEvents: counterpart == nil ? estateEngine.ownerEvents : [],
                             timestamps: tokens,
                             timestampsEnabled: timestampsOn,
                             counterpart: counterpart?.identity.credentialIDHash)
    }

    var body: some View {
        ZStack {
            SealTheme.ink.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 14) {
                    if receiptsFailed { receiptWarning }
                    if events.isEmpty {
                        emptyState
                    } else {
                        ForEach(events) { row($0) }
                    }
                    footer
                }
                .padding(.vertical, 20)
                .frame(maxWidth: 460)
                .frame(maxWidth: .infinity)
                // Pins the content to the scroll view's width so the screen
                // cannot be dragged sideways (docs/COLDSTART.md §19).
                .containerRelativeFrame(.horizontal)
            }
        }
        .navigationTitle(counterpart.map { "Record: \($0.identity.displayName)" } ?? "Record")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            if let onClose {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onClose)
                        .foregroundStyle(SealTheme.brass)
                }
            }
        }
        .task {
            // ReceiptStore does not read the keychain in init, by its own
            // design note, because it gets constructed on every parent body
            // pass inside a NavigationLink destination.
            let store = ReceiptStore(ownerHash: myRoot.credentialIDHash)
            store.loadIfNeeded()
            receipts = store.receipts
            receiptsFailed = store.loadFailed
            timestampsOn = TimestampStore.isEnabled(ownerHash: myRoot.credentialIDHash)
            tokens = TimestampStore.load(ownerHash: myRoot.credentialIDHash)
            // Stamping happens where the record is read, which is the only
            // place it can be: nothing else in the app knows what an event is.
            // Failure is silent by design (TimestampService), so a phone with
            // no signal just shows lines that are not timestamped yet.
            if timestampsOn,
               let updated = await TimestampService.stampPending(
                   events: events, ownerHash: myRoot.credentialIDHash) {
                tokens = updated
            }
        }
    }

    // MARK: - Rows

    private func row(_ event: RecordEvent) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon(event.kind))
                .font(.system(size: 17))
                .foregroundStyle(tint(event.kind))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(event.summary)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text(event.occurredAt.formatted(date: .abbreviated, time: .shortened))
                    if counterpart == nil, let who = event.counterpartName {
                        Text("·")
                        Text(who)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.4))
                stateChip(event.timeProof)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 24)
    }

    private func stateChip(_ proof: RecordEvent.TimeProof) -> some View {
        let text: String
        let color: Color
        switch proof {
        case .deviceClaimed:
            text = "Signed"
            color = .white.opacity(0.45)
        case .timestamped:
            text = "Signed and timestamped"
            color = SealTheme.brass
        case .pendingTimestamp:
            text = "Timestamping"
            color = .orange.opacity(0.85)
        }
        return Text(text)
            .font(.system(.caption2, design: .rounded, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.white.opacity(0.06), in: Capsule())
    }

    private func icon(_ kind: RecordEvent.Kind) -> String {
        switch kind {
        case .metInPerson: "hand.tap.fill"
        case .metReciprocal: "hand.tap"
        case .handover: "shippingbox.fill"
        case .estateCreated: "envelope.badge.shield.half.filled"
        case .custodiansKeyed: "key.fill"
        case .envelopesSealed: "envelope.fill"
        case .heartbeat: "heart.fill"
        case .silenceObserved: "eye"
        case .claimOpened: "exclamationmark.triangle.fill"
        case .objection: "hand.raised.fill"
        case .objectionWithdrawn: "hand.raised"
        case .cancellation: "xmark.octagon.fill"
        case .keyTapped: "key.horizontal.fill"
        case .released: "envelope.open.fill"
        }
    }

    /// Brass only where a key was physically tapped in front of somebody, and
    /// silver for anything vouched for at a distance. The colours carry the
    /// difference before a word is read (UI.md §1).
    private func tint(_ kind: RecordEvent.Kind) -> Color {
        switch kind {
        case .heartbeat, .silenceObserved, .envelopesSealed, .estateCreated: SealTheme.silver
        default: SealTheme.brass
        }
    }

    // MARK: - Furniture

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("Nothing recorded yet.")
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(.white.opacity(0.8))
            Text(counterpart == nil
                 ? "Meeting someone, sealing your envelopes and signing a handover all land here."
                 : "Signing a handover with them lands here.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
        .padding(.vertical, 40)
    }

    /// Loud, because receipts are evidence and losing them quietly is the
    /// failure ReceiptStore.loadFailed exists to prevent.
    private var receiptWarning: some View {
        Text("Handovers could not be read from this phone, so any that exist are missing from this list. Nothing has been deleted.")
            .font(.caption)
            .foregroundStyle(.orange.opacity(0.9))
            .fixedSize(horizontal: false, vertical: true)
            .padding(16)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 24)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Every line here is signed by the phone that made it, and can be checked again later against the public directory.")
            if timestampsOn {
                Text("Seal asks a timestamp authority to sign each line's digest, and only the digest ever leaves this phone. It keeps the token that comes back. That token's own signature is checked when you export the record, not here.")
                Text("A line still marked Signed has no token yet. It gets one the next time this screen opens with a connection.")
            } else {
                Text("The times are that phone's own clock, so Seal can prove who signed something and that its contents have not changed, but not when it happened. Turn on independent timestamps on the You screen to close that.")
            }
            Text("A line here says credential A did something with credential B. It is not proof of anyone's legal identity, and it does not say whether what they agreed to was wise.")
        }
        .font(.caption2)
        .foregroundStyle(.white.opacity(0.4))
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.top, 14)
    }
}
