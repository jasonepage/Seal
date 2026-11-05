// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

//  PolicyView.swift
//  Seal
//
//  THE RULE. Four numbers and one choice, each explained in a sentence a
//  person can read back and agree with. The defaults are the brief's: 90
//  days of silence, 21 of warnings, 14 of grace, and pause on objection.

struct PolicyView: View {
    @Bindable var estateEngine: EstateEngine
    let onClose: () -> Void

    @State private var policy: ReleasePolicy = ReleasePolicy(threshold: 1)
    @State private var problem: String?
    @State private var step = 0
    /// Most people answer only the first few questions. The rest keep safe
    /// defaults (21 days of warnings, 14 more, pause on an objection, a key
    /// check every year) and show only after "More options" on the last step.
    @State private var showMore = false

    private var custodianCount: Int { max(estateEngine.estate?.custodians.count ?? 0, 1) }
    /// The kind is chosen once, before the first seal (PRODUCT.md section 17).
    private var kindLocked: Bool { estateEngine.sealedKind != nil }
    private var kindBinding: Binding<ReleasePolicy.Kind> {
        Binding(get: { policy.kind }, set: { policy = policy.shaped(as: $0) })
    }

    private enum Question {
        case kind, silence, threshold, warning, grace, objection, confirmation, review
    }

    private var questions: [Question] {
        switch policy.kind {
        case .quiet:
            showMore
                ? [.silence, .threshold, .warning, .grace, .objection, .confirmation, .review]
                : [.silence, .threshold, .review]
        case .breakGlass:
            showMore ? [.threshold, .confirmation, .review] : [.threshold, .review]
        case .rightAway:
            [.review]
        }
    }

    private var currentQuestion: Question {
        questions[min(step, questions.count - 1)]
    }

    /// Under the "how many must agree" stepper. At a rule of one it says
    /// plainly what one key holder could do (audit H1).
    private var thresholdFooter: String {
        let count = estateEngine.estate?.custodians.count ?? 0
        guard policy.threshold == 1 else {
            return "Any \(policy.threshold) of your \(count) key holders must each tap their key. One tap from you stops all of it."
        }
        let who = count <= 1
            ? "Your one key holder can act alone."
            : "Any one of your \(count) key holders can act alone."
        return who + " One tap from you stops all of it. " + ReleasePolicy.oneKeyCaution(custodianCount: count)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SealTheme.ink.ignoresSafeArea()
                VStack(spacing: 0) {
                    progress
                    ScrollView {
                        question
                            .padding(20)
                            .frame(maxWidth: 520)
                            .frame(maxWidth: .infinity)
                            .containerRelativeFrame(.horizontal)
                    }
                    controls
                }
            }
            .navigationTitle(policy.kind.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onClose).foregroundStyle(SealTheme.brass) }
            }
            .onAppear {
                policy = estateEngine.estate?.policy ?? ReleasePolicy(threshold: 1)
                step = 0
                showMore = false
            }
            .onChange(of: policy.kind) { _, _ in
                problem = nil
                step = min(step, questions.count - 1)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(questions.indices, id: \.self) { index in
                Capsule()
                    .fill(index <= step ? SealTheme.brass : .white.opacity(0.12))
                    .frame(height: 4)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .accessibilityLabel("Step \(step + 1) of \(questions.count)")
    }

    @ViewBuilder
    private var question: some View {
        switch currentQuestion {
        case .kind:
            prompt("When should this open?", policy.kind.explanation + (kindLocked ? " This choice is fixed after the first seal." : "")) {
                VStack(spacing: 10) {
                    ForEach(ReleasePolicy.Kind.allCases, id: \.self) { kind in
                        choice(kind.label, selected: policy.kind == kind) {
                            kindBinding.wrappedValue = kind
                        }
                        .disabled(kindLocked)
                    }
                }
            }
        case .silence:
            prompt("How long can you go quiet?", "Opening Seal once resets the clock."
                   + (policy.silenceDays < 30 ? " " + ReleasePolicy.shortSilenceCaution : "")) {
                Picker("Days", selection: $policy.silenceDays) {
                    ForEach(ReleasePolicy.allowedSilenceDays, id: \.self) { Text("\($0) days").tag($0) }
                }
                .pickerStyle(.wheel)
                .frame(height: 150)
            }
        case .threshold:
            prompt("How many people must agree?", thresholdFooter) {
                Stepper(value: $policy.threshold, in: 1...custodianCount) {
                    Text("\(policy.threshold) of \(estateEngine.estate?.custodians.count ?? 0)")
                        .font(.system(.title2, design: .rounded, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
        case .warning:
            prompt("How long should we warn you?", "Seal warns you every day. Opening the app stops the process.") {
                Stepper("\(policy.warningDays) days", value: $policy.warningDays, in: 1...90)
                    .font(.title3.bold())
            }
        case .grace:
            prompt("Add a final waiting period?", "Nobody can approve the opening during this time.") {
                Stepper(policy.graceDays == 0 ? "No extra wait" : "\(policy.graceDays) days",
                        value: $policy.graceDays, in: 0...90)
                    .font(.title3.bold())
            }
        case .objection:
            prompt("What if someone objects?", policy.objectionBehavior == .pause
                   ? "The countdown stops until they withdraw the objection."
                   : "The claim ends. A key holder must start a new one from the beginning.") {
                VStack(spacing: 10) {
                    ForEach(ReleasePolicy.ObjectionBehavior.allCases, id: \.self) { behavior in
                        choice(behavior.label, selected: policy.objectionBehavior == behavior) {
                            policy.objectionBehavior = behavior
                        }
                    }
                }
            }
        case .confirmation:
            prompt("How often should keys be checked?", "This only confirms that each key holder still has their key. It cannot open anything.") {
                Picker("Key check", selection: $policy.custodyConfirmMonths) {
                    ForEach(ReleasePolicy.allowedCustodyConfirmMonths, id: \.self) {
                        Text($0 == 12 ? "Every year" : ($0 == 24 ? "Every 2 years" : "Every \($0) months")).tag($0)
                    }
                }
                .pickerStyle(.wheel)
                .frame(height: 150)
            }
        case .review:
            prompt("Ready to save?", "You can change these numbers again later.") {
                Text(policy.summary(custodianCount: estateEngine.estate?.custodians.count ?? 0))
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .foregroundStyle(SealTheme.brass)
                    .fixedSize(horizontal: false, vertical: true)
                if !showMore && policy.kind != .rightAway {
                    Button("More options") {
                        withAnimation {
                            showMore = true
                            let first: Question = policy.kind == .quiet ? .warning : .confirmation
                            step = questions.firstIndex(of: first) ?? step
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.bordered)
                }
            }
        }

        if let problem {
            Text(problem).font(.callout).foregroundStyle(.orange).padding(.top, 14)
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            if step > 0 {
                Button("Back") { withAnimation { step -= 1 } }
                    .buttonStyle(.bordered)
            }
            Button(currentQuestion == .review ? "Save rule" : "Continue") {
                if currentQuestion == .review {
                    do { try estateEngine.setPolicy(policy); onClose() }
                    catch { problem = error.localizedDescription }
                } else {
                    withAnimation { step = min(step + 1, questions.count - 1) }
                }
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
        }
        .tint(SealTheme.brass)
        .padding(20)
        .background(.ultraThinMaterial)
    }

    private func prompt<Content: View>(_ title: String, _ help: String,
                                       @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(title)
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Text(help)
                .font(.body)
                .foregroundStyle(.white.opacity(0.62))
                .fixedSize(horizontal: false, vertical: true)
            content().tint(SealTheme.brass)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 22))
    }

    private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            }
            .foregroundStyle(selected ? SealTheme.brass : .white)
            .padding(16)
            .background(selected ? SealTheme.brass.opacity(0.12) : .white.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}
