// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

//  GuardedEstateView.swift
//  Seal
//
//  A KEY YOU HOLD FOR SOMEBODY ELSE. What state their envelopes are in, the
//  countdown when a claim is running, and the buttons a custodian has:
//  start a claim, object, withdraw, tap your key, combine the keys. A
//  recipient sees the envelopes here after release.
//
//  Every button is gated by the state machine. The screen never decides
//  anything; it asks ReleaseMachine and shows the answer.

struct GuardedEstateView: View {
    let guarded: GuardedEstate
    let myRoot: RootIdentity
    @Bindable var ceremony: CeremonyManager
    @Bindable var estateEngine: EstateEngine
    @Bindable var appLock: AppLock

    @State private var working = false
    @State private var error: String?
    @State private var showClaimSheet = false
    @State private var showObjectSheet = false
    @State private var claimReason = ""
    @State private var objectionNote = ""
    @State private var reveal: RevealPayload?
    @State private var showCapsule = false

    private var snapshot: ReleaseSnapshot? { estateEngine.guardedSnapshots[guarded.estateID] }
    private var state: ReleaseState? { estateEngine.state(of: guarded.estateID) }
    private var timeline: ReleaseTimeline? { estateEngine.timeline(of: guarded.estateID) }
    private var events: [EstateEvent] { estateEngine.guardedEvents[guarded.estateID] ?? [] }
    private var live: GuardedEstate { estateEngine.guarded.first { $0.estateID == guarded.estateID } ?? guarded }
    /// Set once the owner deleted their account (DepartureRules.swift).
    private var departure: DepartureRules.Departure? { estateEngine.departure(of: guarded.estateID) }
    private var cancelled: Bool { departure?.keepEnvelopes == false }

    var body: some View {
        ZStack {
            SealTheme.ink.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 18) {
                    if let departure { departureCard(departure) }
                    if !cancelled { stateCard }
                    if live.isCustodian, !cancelled { custodyCard }
                    if live.isCustodian, !cancelled { custodianActions }
                    if live.isRecipient, !(cancelled && state != .released) { recipientCard }
                    ruleCard
                    logCard
                    Button { showCapsule = true } label: {
                        Label("Save a copy of this record", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered).tint(.white)
                    .parentTapTarget()
                    .padding(.horizontal, 20)
                }
                .padding(.vertical, 16)
                .frame(maxWidth: 520).frame(maxWidth: .infinity)
                .containerRelativeFrame(.horizontal)
            }
        }
        .navigationTitle(live.ownerName.isEmpty ? "Their envelopes" : "\(live.ownerName)'s envelopes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { await estateEngine.refreshGuarded() }
        .refreshable { await estateEngine.refreshGuarded() }
        .onReceive(NotificationCenter.default.publisher(for: Clocks.changed)) { _ in
            Task { await estateEngine.refreshGuarded() }
        }
        .sheet(isPresented: $showClaimSheet) { claimSheet }
        .sheet(isPresented: $showObjectSheet) { objectSheet }
        .sheet(isPresented: $showCapsule) {
            CapsuleExportSheet(estateID: guarded.estateID, estateEngine: estateEngine, onClose: { showCapsule = false })
        }
        .sheet(item: $reveal) { payload in
            RevealView(envelopes: payload.envelopes, estateID: guarded.estateID, ownerName: live.ownerName,
                       estateEngine: estateEngine, appLock: appLock, onClose: { reveal = nil })
        }
        .alert("Seal", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    // MARK: - State

    private var stateCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(EstateHomeView.stateLine(state, guarded: live))
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .foregroundStyle(tint)
            if let s = snapshot {
                if let last = s.lastHeartbeatAt {
                    Text("\(live.ownerName) last checked in \(last.formatted(date: .abbreviated, time: .shortened)), \(ReleaseMachine.silentDays(s, now: estateEngine.now)) days ago.")
                } else {
                    Text("\(live.ownerName) has never checked in since sealing.")
                }
                if let t = timeline {
                    countdown(t)
                }
                if let next = ReleaseMachine.nextTransition(s, now: estateEngine.now), state != .active {
                    Text("Next step \(next.formatted(date: .abbreviated, time: .shortened)).")
                        .foregroundStyle(.white.opacity(0.55))
                }
                let taps = ReleaseMachine.validAuthorizations(s, now: estateEngine.now).count
                if state == .claimOpen || state == .authorized {
                    Text("\(taps) of \(s.policy.threshold) keys tapped.")
                        .font(.system(.headline, design: .rounded)).foregroundStyle(SealTheme.brass)
                }
            }
        }
        .font(.callout).foregroundStyle(.white.opacity(0.85))
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 20)
    }

    /// The owner deleted their account. Said first, in plain words, with
    /// the dates that follow from the rule when they kept the envelopes.
    private func departureCard(_ d: DepartureRules.Departure) -> some View {
        let name = live.ownerName.isEmpty ? "The owner" : live.ownerName
        let day = d.at.formatted(date: .abbreviated, time: .omitted)
        return VStack(alignment: .leading, spacing: 8) {
            Label("\(name) deleted their Seal account", systemImage: "person.crop.circle.badge.xmark")
                .font(.headline).foregroundStyle(.orange)
            if d.keepEnvelopes {
                Text("On \(day), \(name) deleted their account and chose to keep these envelopes for their family. \(name) can no longer check in, so the rule will run its course.")
                if let s = snapshot {
                    let claim = DepartureRules.earliestClaim(s).formatted(date: .abbreviated, time: .omitted)
                    let open = DepartureRules.earliestOpening(s).formatted(date: .abbreviated, time: .omitted)
                    Text(live.isCustodian
                         ? "A key holder can start opening them on \(claim). If nobody objects, they could open around \(open) at the earliest. It still takes your key."
                         : "The key holders can start opening them on \(claim). If nobody objects, they could open around \(open) at the earliest.")
                        .foregroundStyle(.white)
                }
            } else {
                Text("On \(day), \(name) deleted their account and cancelled these envelopes. They can never be opened, by anyone. Nothing more is needed from you.")
            }
        }
        .font(.callout).foregroundStyle(.white.opacity(0.8))
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 20)
    }

    private func countdown(_ t: ReleaseTimeline) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            row("Claim opened", t.claimOpenedAt)
            row("Warnings end", t.warningEndsAt)
            row("Keys can be tapped", t.claimOpensAt)
            if t.pausedTotal > 0 {
                Text("Paused \(Int(t.pausedTotal / 86_400)) days by an objection.")
                    .font(.caption).foregroundStyle(.orange.opacity(0.9))
            }
        }
        .padding(.top, 4)
    }

    private func row(_ label: String, _ date: Date) -> some View {
        HStack {
            Text(label).foregroundStyle(.white.opacity(0.6))
            Spacer()
            Text(date.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(.white)
        }
        .font(.callout)
    }

    private var tint: Color {
        switch state {
        case .warning?, .grace?, .claimOpen?, .authorized?, .overdue?, .objected?: .orange
        case .released?: SealTheme.brass
        default: SealTheme.silver
        }
    }

    // MARK: - Custodian actions

    private var custodianActions: some View {
        VStack(spacing: 10) {
            if let s = snapshot {
                let now = estateEngine.now
                if ReleaseMachine.custodianCanClaim(s, now: now) {
                    action("Start a claim", icon: "exclamationmark.triangle.fill", tint: .orange,
                           note: "\(live.ownerName) gets a warning every day for \(s.policy.warningDays) days. If they open Seal once, this stops.") {
                        showClaimSheet = true
                    }
                }
                if ReleaseMachine.custodianCanAuthorize(s, now: now, custodianHash: myRoot.credentialIDHash) {
                    action("Tap my key", icon: "key.fill", tint: SealTheme.brass,
                           note: "Have your security key ready. Your tap authorises the release and sends your share of the key to whoever started the claim.") {
                        Task { await run { try await estateEngine.authorize(estateID: guarded.estateID, ceremony: ceremony) } }
                    }
                }
                if ReleaseMachine.claimantCanRelease(s, now: now), s.claim?.claimantHash == myRoot.credentialIDHash {
                    action("Combine the keys", icon: "envelope.open.fill", tint: SealTheme.brass,
                           note: "Enough custodians have tapped. This recovers the key and releases the envelopes to the people they are written for. It cannot be undone.") {
                        Task { await run { try await estateEngine.release(estateID: guarded.estateID) } }
                    }
                }
                if state?.claimIsLive == true {
                    let mine = s.objections.contains { $0.custodianHash == myRoot.credentialIDHash && $0.withdrawnAt == nil }
                    if mine {
                        action("Withdraw my objection", icon: "hand.raised", tint: .white, note: nil) {
                            Task { await run { try await estateEngine.object(estateID: guarded.estateID, note: "", withdraw: true) } }
                        }
                    } else if state != .authorized {
                        action("Object", icon: "hand.raised.fill", tint: .white,
                               note: s.policy.objectionBehavior == .pause
                                    ? "Stops the countdown until you withdraw. Use it if you have reason to think \(live.ownerName) is alive."
                                    : "Kills this claim. A new one has to start from the beginning.") {
                            showObjectSheet = true
                        }
                    }
                }
            }
        }
    }

    // MARK: - "I still have my key"

    /// The yearly receipt (CustodyConfirmation). When it is due the card
    /// asks plainly and the button is brass; the rest of the year it is
    /// one quiet line saying when they last confirmed. Never counts toward
    /// a release, and the card says so.
    private var custodyCard: some View {
        let last = estateEngine.myLastCustodyConfirmation(estateID: guarded.estateID)
        let due = estateEngine.custodyConfirmationDue(estateID: guarded.estateID)
        let months = snapshot?.policy.custodyConfirmMonths ?? ReleasePolicy.defaultCustodyConfirmMonths
        return VStack(alignment: .leading, spacing: 10) {
            Label(due ? "Do you still have the key \(live.ownerName) gave you?" : "Your key",
                  systemImage: due ? "key.viewfinder" : "checkmark.seal")
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(due ? SealTheme.brass : .white.opacity(0.85))
            if due {
                Text("Find it and tap it to this phone. That writes one signed line in \(live.ownerName)'s record saying you still have it. It does not open anything and it is not a vote for anything.")
                    .font(.callout).foregroundStyle(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    Task { await run { try await estateEngine.confirmCustody(estateID: guarded.estateID, ceremony: ceremony) } }
                } label: {
                    HStack {
                        if working { ProgressView().tint(SealTheme.ink) }
                        Label("Tap my key to confirm", systemImage: "key.fill").font(.system(.headline, design: .rounded))
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent).tint(SealTheme.brass).foregroundStyle(SealTheme.ink)
                .disabled(working || DemoFixtures.isActive)
                .parentTapTarget(60)
            } else if let last {
                Text("You confirmed you still have it \(SecretAge.ago(since: last, now: estateEngine.now)). Seal asks again every \(months == 12 ? "year" : "\(months) months").")
                    .font(.caption).foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Every \(months == 12 ? "year" : "\(months) months") Seal will ask you to tap your key, so \(live.ownerName) knows it is still in good hands.")
                    .font(.caption).foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.white.opacity(due ? 0.08 : 0.04), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(due ? SealTheme.brass.opacity(0.35) : .clear, lineWidth: 1))
        .padding(.horizontal, 20)
    }

    private func action(_ title: String, icon: String, tint: Color, note: String?, _ perform: @escaping () -> Void) -> some View {
        VStack(spacing: 6) {
            Button(action: perform) {
                HStack {
                    if working { ProgressView().tint(SealTheme.ink) }
                    Label(title, systemImage: icon).font(.system(.headline, design: .rounded))
                }
                .frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent).tint(tint)
            .foregroundStyle(tint == .white ? SealTheme.ink : (tint == SealTheme.brass ? SealTheme.ink : .white))
            .disabled(working || DemoFixtures.isActive)
            .parentTapTarget(60)
            if let note {
                Text(note).font(.caption).foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 20)
    }

    private func run(_ body: () async throws -> Void) async {
        working = true
        defer { working = false }
        do { try await body() } catch { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    }

    // MARK: - Recipient

    private var recipientCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Written for you").font(.headline).foregroundStyle(.white)
            if state == .released {
                Text("The envelopes have been released. Open them here. They open in the order \(live.ownerName) chose.")
                    .font(.callout).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
                Button {
                    Task {
                        await run {
                            guard await AppLock.confirmSeal(ownerHash: myRoot.credentialIDHash) else { return }
                            reveal = RevealPayload(envelopes: try await estateEngine.openEnvelopes(estateID: guarded.estateID))
                        }
                    }
                } label: {
                    Label("Open my envelopes", systemImage: "envelope.open.fill").frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent).tint(SealTheme.brass)
                .disabled(working || DemoFixtures.isActive)
                .parentTapTarget(60)
            } else {
                Text("\(live.ownerName) has written you something. It is sealed, and stays sealed until their custodians release it. Nobody, including us, can open it early.")
                    .font(.callout).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 20)
    }

    // MARK: - Rule and log

    private var ruleCard: some View {
        Group {
            if let epoch = live.epoch, let s = snapshot {
                VStack(alignment: .leading, spacing: 6) {
                    Text("The rule").font(.headline).foregroundStyle(.white)
                    Text(s.policy.summary(custodianCount: epoch.custodianHashes.count))
                        .font(.callout).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
                    Text("Key shares issued in round \(epoch.epoch). Your share is checked against the owner's signed commitment before it is ever used.")
                        .font(.caption).foregroundStyle(.white.opacity(0.45)).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 20)
            }
        }
    }

    private var logCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What has happened").font(.headline).foregroundStyle(.white)
            if events.isEmpty {
                Text("Nothing yet.").font(.callout).foregroundStyle(.white.opacity(0.5))
            }
            ForEach(events.sorted { $0.occurredAtEpoch > $1.occurredAtEpoch }.prefix(30)) { e in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: e.timestampToken == nil ? "signature" : "checkmark.seal.fill")
                        .font(.caption).foregroundStyle(e.timestampToken == nil ? .white.opacity(0.4) : SealTheme.brass)
                        .padding(.top, 3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line(e)).font(.callout).foregroundStyle(.white.opacity(0.85))
                        Text(ReleaseFeed.effectiveTime(e).formatted(date: .abbreviated, time: .shortened)
                             + (e.timestampToken == nil ? " (their clock)" : " (timestamped)"))
                            .font(.caption2).foregroundStyle(.white.opacity(0.4))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 20)
    }

    private func line(_ e: EstateEvent) -> String {
        let who = e.actorHash == myRoot.credentialIDHash ? "You" : (e.actorHash == live.ownerHash ? live.ownerName : "A key holder")
        switch e.kind {
        case .estateCreated: return "\(who) started the envelopes."
        case .epochPublished: return "\(who) issued key shares."
        case .policyChanged: return "\(who) changed the rule."
        case .vaultUpdated: return "\(who) sealed the envelopes."
        case .heartbeat: return "\(who) checked in."
        case .silenceObserved: return "\(who) noted the silence."
        case .releaseClaimed: return "\(who) started a claim."
        case .objection: return "\(who) objected."
        case .objectionWithdrawn: return "\(who) withdrew an objection."
        case .cancellation: return "\(who) stopped the claim."
        case .authorization: return "\(who) tapped a key."
        case .released: return "\(who) combined the keys. Released."
        case .custodyConfirmed: return "\(who) confirmed they still have their key."
        case .ownerDeparted:
            return DepartureRules.historyLine(name: who, keep: e.body(DepartureBody.self)?.keepEnvelopes ?? false)
        }
    }

    // MARK: - Sheets

    private var claimSheet: some View {
        NavigationStack {
            ZStack {
                SealTheme.ink.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 16) {
                    Text("Start a claim on \(live.ownerName)'s envelopes")
                        .font(.system(.title3, design: .rounded, weight: .semibold)).foregroundStyle(.white)
                    Text("Do this only if you believe \(live.ownerName) has died or cannot ever come back. They get a warning every day. Every other custodian is told today. If \(live.ownerName) opens Seal once, the claim ends and everyone sees that you started it.")
                        .font(.callout).foregroundStyle(.white.opacity(0.75)).fixedSize(horizontal: false, vertical: true)
                    TextField("Why (kept in the record)", text: $claimReason)
                        .padding(14).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14)).foregroundStyle(.white)
                    Button {
                        showClaimSheet = false
                        Task { await run { try await estateEngine.openClaim(estateID: guarded.estateID, reason: claimReason) } }
                    } label: { Text("Start the claim").frame(maxWidth: .infinity).padding(.vertical, 8) }
                    .buttonStyle(.borderedProminent).tint(.orange)
                    .parentTapTarget(60)
                    Spacer()
                }
                .padding(20)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showClaimSheet = false }.foregroundStyle(SealTheme.brass) } }
        }
        .preferredColorScheme(.dark)
    }

    private var objectSheet: some View {
        NavigationStack {
            ZStack {
                SealTheme.ink.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 16) {
                    Text("Object to this claim").font(.system(.title3, design: .rounded, weight: .semibold)).foregroundStyle(.white)
                    TextField("Why (kept in the record)", text: $objectionNote)
                        .padding(14).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14)).foregroundStyle(.white)
                    Button {
                        showObjectSheet = false
                        Task { await run { try await estateEngine.object(estateID: guarded.estateID, note: objectionNote) } }
                    } label: { Text("Object").frame(maxWidth: .infinity).padding(.vertical, 8) }
                    .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(SealTheme.ink)
                    .parentTapTarget(60)
                    Spacer()
                }
                .padding(20)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showObjectSheet = false }.foregroundStyle(SealTheme.brass) } }
        }
        .preferredColorScheme(.dark)
    }
}

struct RevealPayload: Identifiable {
    let id = UUID()
    let envelopes: [EstateEngine.OpenedEnvelope]
}
