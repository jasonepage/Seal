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

    private var custodianCount: Int { max(estateEngine.estate?.custodians.count ?? 0, 1) }

    var body: some View {
        NavigationStack {
            ZStack {
                SealTheme.ink.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        Text(policy.summary(custodianCount: estateEngine.estate?.custodians.count ?? 0))
                            .font(.system(.title3, design: .rounded, weight: .semibold))
                            .foregroundStyle(SealTheme.brass)
                            .fixedSize(horizontal: false, vertical: true)

                        block("How long you can go quiet",
                              "If you do not open Seal for this long, your custodians may start the process. Opening the app once resets it.") {
                            Picker("Silence", selection: $policy.silenceDays) {
                                ForEach(ReleasePolicy.allowedSilenceDays, id: \.self) { Text("\($0) days").tag($0) }
                            }
                            .pickerStyle(.segmented)
                        }

                        block("How many custodians must agree",
                              "Any \(policy.threshold) of your \(estateEngine.estate?.custodians.count ?? 0) custodians must each tap their key. One tap from you stops all of it.") {
                            Stepper("\(policy.threshold) of \(estateEngine.estate?.custodians.count ?? 0)", value: $policy.threshold, in: 1...custodianCount)
                                .foregroundStyle(.white)
                        }

                        block("How long you are warned",
                              "After a claim starts you are warned every day for this long, on every channel Seal has.") {
                            Stepper("\(policy.warningDays) days", value: $policy.warningDays, in: 1...90).foregroundStyle(.white)
                        }

                        block("A quiet period after the warnings",
                              "Nothing can be tapped until this has also passed.") {
                            Stepper("\(policy.graceDays) days", value: $policy.graceDays, in: 0...90).foregroundStyle(.white)
                        }

                        block("If a custodian objects",
                              policy.objectionBehavior == .pause
                                ? "The countdown stops until they withdraw the objection. Nothing else changes."
                                : "The claim is dead. A new one has to be started from the beginning.") {
                            Picker("Objection", selection: $policy.objectionBehavior) {
                                ForEach(ReleasePolicy.ObjectionBehavior.allCases, id: \.self) { Text($0.label).tag($0) }
                            }
                            .pickerStyle(.segmented)
                        }

                        if let problem { Text(problem).font(.callout).foregroundStyle(.orange) }

                        Text("Changing who must agree issues fresh key shares the next time you seal. Your envelopes are not touched.")
                            .font(.caption).foregroundStyle(.white.opacity(0.45)).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(20)
                    .frame(maxWidth: 520).frame(maxWidth: .infinity)
                    .containerRelativeFrame(.horizontal)
                }
            }
            .navigationTitle("The rule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onClose).foregroundStyle(SealTheme.brass) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do { try estateEngine.setPolicy(policy); onClose() }
                        catch { problem = error.localizedDescription }
                    }
                    .foregroundStyle(SealTheme.brass)
                }
            }
            .onAppear { policy = estateEngine.estate?.policy ?? ReleasePolicy(threshold: 1) }
        }
        .preferredColorScheme(.dark)
    }

    private func block<T: View>(_ title: String, _ explanation: String, @ViewBuilder control: () -> T) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline).foregroundStyle(.white)
            control().tint(SealTheme.brass)
            Text(explanation).font(.callout).foregroundStyle(.white.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
    }
}
