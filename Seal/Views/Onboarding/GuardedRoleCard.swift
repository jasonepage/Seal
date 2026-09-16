// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

//  GuardedRoleCard.swift
//  Seal
//
//  THE OTHER TWO PEOPLE. A key holder and a recipient install Seal because
//  somebody asked them to, register, and land on a home screen written for
//  the owner. This file is the part of the home screen that speaks to them.
//
//    GuardedRoleCard       one estate this phone has a part in, in the
//                          words of the part this phone plays.
//    PeopleYouWouldDoThisForCard
//                          the question for somebody who has nothing of
//                          their own yet.
//    HandoverDoneView      on the OWNER's phone, right after a key holder
//                          tapped their key to accept custody, while they
//                          are still standing there holding it.
//
//  Numbers. The phone knows how many recipients an estate has and nothing
//  about which envelopes are for whom until release (VaultBody.tableIDs,
//  docs/GOTCHAS.md). So this card never prints a count of envelopes. It
//  says "envelopes".
//
//  Every recipient is a Seal identity met in person. Nothing here is
//  designed around any other rule.

// MARK: - One estate, in the words of this phone's part

struct GuardedRoleCard<Details: View>: View {
    let guarded: GuardedEstate
    let state: ReleaseState?
    let snapshot: ReleaseSnapshot?
    let onExplain: (OnboardingRole, OnboardingNumbers) -> Void
    @ViewBuilder let details: () -> Details

    private var name: String { guarded.ownerName.isEmpty ? "Someone" : guarded.ownerName }
    private var numbers: OnboardingNumbers { OnboardingNumbers(guarded: guarded, snapshot: snapshot) }

    private var headline: String {
        switch (guarded.isRecipient, guarded.isCustodian) {
        case (true, true): "\(name) sealed envelopes for you, and you hold one of the keys."
        case (true, false): "\(name) sealed envelopes for you."
        case (false, true): "You hold a key for \(name)."
        case (false, false): "\(name)'s envelopes"
        }
    }

    private var explainRole: OnboardingRole {
        guarded.isCustodian ? .keyHolder : .recipient
    }

    /// The most important sentence for this person, by role. Both when
    /// they are both.
    private var promise: String {
        var lines: [String] = []
        if guarded.isRecipient {
            lines.append("You can open them when the time comes. Nobody can open them early. Not Apple, not us, not anyone holding a key.")
        }
        if guarded.isCustodian {
            // Same check as HandoverDoneView: at a threshold of 1 the
            // reassuring sentence is the untrue one.
            if numbers.oneIsEnough {
                lines.append("\(name) chose a rule that needs only one person, so your key alone can open everything once the silence and the warnings have run their course. Nothing opens before that. Your job is to keep this app installed and to still be findable in ten years.")
            } else {
                let who = numbers.exact
                    ? "You are one of \(numbers.custodianCount) key holders, and it takes \(numbers.threshold) of you together."
                    : "You are one of several key holders, and it takes more than one key."
                lines.append("You cannot open anything with your key, and neither can anyone else with one. \(who) Your job is to keep this app installed and to still be findable in ten years.")
            }
        }
        return lines.joined(separator: " ")
    }

    /// Where things stand, in plain words, for this role.
    private var status: String {
        switch state {
        case .none:
            return "Waiting for \(name) to seal."
        case .active?, .cancelled?:
            var line: String
            if let last = snapshot?.lastHeartbeatAt {
                line = "\(name) checked in \(last.formatted(.relative(presentation: .named)))."
            } else {
                line = "\(name) has sealed."
            }
            line += guarded.isCustodian ? " Nothing for you to do." : " All is well."
            if state == .cancelled {
                line += " A claim was started once and \(name) stopped it."
            }
            return line
        case .overdue?:
            return guarded.isCustodian
                ? "\(name) has been quiet past the limit. You may start a claim from Details."
                : "\(name) has been quiet past the limit. The key holders have been told."
        case .warning?:
            return "A claim is open. \(name) is being warned every day and can stop it with one tap."
        case .grace?:
            return "The warnings are over. A quiet period is running before keys can be tapped."
        case .claimOpen?:
            return guarded.isCustodian ? "Keys can be tapped now. Yours is one of them." : "Keys can be tapped now."
        case .authorized?:
            return "Enough keys have been tapped. Waiting for them to be combined."
        case .released?:
            return guarded.isRecipient
                ? "Released. Your envelopes are waiting in Details."
                : "Released. The envelopes have opened for the people they were written for."
        case .objected?:
            return "A key holder objected. The countdown is paused."
        }
    }

    private var statusTint: Color {
        switch state {
        case .warning?, .grace?, .claimOpen?, .authorized?, .overdue?, .objected?: .orange
        case .released?: SealTheme.brass
        default: .white.opacity(0.6)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: guarded.isCustodian ? "key.fill" : "envelope.fill")
                    .font(.title3)
                    .foregroundStyle(state == .released ? SealTheme.brass : SealTheme.silver)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                Text(headline)
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(promise)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)

            Text(status)
                .font(.footnote)
                .foregroundStyle(statusTint)
                .fixedSize(horizontal: false, vertical: true)

            // Two buttons, stacked so they never fight for width at big
            // text sizes.
            VStack(spacing: 10) {
                Button {
                    onExplain(explainRole, numbers)
                } label: {
                    Label("See how it opens", systemImage: "play.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SealSecondaryButtonStyle())
                .parentTapTarget()

                details()
                    .buttonStyle(.plain)
                    .parentTapTarget()
            }
            .padding(.top, 4)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 20)
    }
}

/// The label for the Details link inside a GuardedRoleCard, so the card
/// and the home screen agree on how it looks.
struct GuardedDetailsLabel: View {
    var body: some View {
        HStack {
            Text("Details")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.9))
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
    }
}

// MARK: - The question

/// For a phone that guards something for somebody else and has nothing of
/// its own. It sits under the role cards, above the owner's own sections.
struct PeopleYouWouldDoThisForCard: View {
    let onWrite: () -> Void
    let onExplain: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Do you have people you would do this for?")
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Text("Sealed envelopes for the people you leave behind: the passwords, the letters, the things only you know. Writing your own takes an evening, and this app is already on your phone.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 10) {
                Button(action: onWrite) {
                    Label("Write an envelope", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SealPrimaryButtonStyle())
                .parentTapTarget()
                Button(action: onExplain) {
                    Text("Show me how it works")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SealSecondaryButtonStyle())
                .parentTapTarget()
            }
            .padding(.top, 4)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 20)
    }
}

// MARK: - Right after the handover

/// Shown on the OWNER's phone the moment a key holder's tap is signed.
/// The key holder is standing next to the owner, has just tapped, and has
/// just understood what the key is for. Two things, in this order: what
/// their job is, and the question.
///
/// It replaces the "Handover signed" alert in PersonView. The brass mark
/// is the two-sided receipt: a trust moment, so brass is right here.
struct HandoverDoneView: View {
    let custodianName: String
    let ownerName: String
    let numbers: OnboardingNumbers
    let onDone: () -> Void

    @State private var showHow = false
    @Environment(\.parentMode) private var parentMode

    var body: some View {
        ZStack {
            SealTheme.ink.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 24) {
                    SealMark(size: 110, trust: true, pressOnAppear: true, pulseOnAppear: true)
                        .padding(.top, 28)

                    Text("Signed. \(custodianName) holds a key now.")
                        .font(.system(.title, design: .rounded, weight: .bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Both of you signed it. The record shows \(custodianName) took a key from \(ownerName) today.")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("\(custodianName), three things to know")
                            .font(.headline)
                            .foregroundStyle(.white)
                        // The first bullet CHECKS THE RULE before it
                        // reassures anybody. At a threshold of 1 the usual
                        // sentence is false, and false in the worst
                        // direction: it tells this person they are powerless
                        // while handing them sole control of the estate.
                        if numbers.oneIsEnough {
                            bullet("\(ownerName) chose a rule that needs only one person, so your key alone can open everything, once they have been quiet for \(numbers.silenceDays) days and all the warnings have run. Nobody can open anything before that.")
                        } else {
                            bullet("You cannot open anything with this key, and neither can anyone else holding one. It takes \(numbers.threshold) of \(ownerName)'s \(numbers.custodianCount) key holders, acting together.")
                        }
                        bullet("Keep Seal on this phone, and sign in again if you get a new one. That is the whole job, and it may be years before anyone needs you.")
                        bullet("If \(ownerName) goes quiet for \(numbers.silenceDays) days, this app tells you. Until then there is nothing to do.")
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20))

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Do you have people you would do this for?")
                            .font(.system(.title3, design: .rounded, weight: .semibold))
                            .foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Seal is already on your phone. When you get home, open it and write your first envelope. It takes an evening.")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.75))
                            .fixedSize(horizontal: false, vertical: true)
                        Button { showHow = true } label: {
                            Text("Show me how it works")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(SealSecondaryButtonStyle())
                        .parentTapTarget()
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20))

                    Button(action: onDone) {
                        Text("Done").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SealPrimaryButtonStyle())
                    .parentTapTarget()
                    .padding(.bottom, 24)
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: 460)
                .frame(maxWidth: .infinity)
                .containerRelativeFrame(.horizontal)
            }
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: $showHow) {
            SealOnboardingView(numbers: numbers, initialRole: .sealer, onDone: { showHow = false })
                .environment(\.parentMode, parentMode)
                .parentTypeScale()
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle().fill(Color.white.opacity(0.6)).frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(text)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview("Handover done") {
    HandoverDoneView(custodianName: "Sarah", ownerName: "Karen",
                     numbers: OnboardingNumbers(silenceDays: 90, warningDays: 21, graceDays: 14,
                                                threshold: 2, custodianCount: 3, exact: true),
                     onDone: {})
}
