// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

//  TimeTravelView.swift
//  Seal
//
//  DEBUG ONLY. Swaps the wall clock for a SimulatedClock and advances it by
//  days, so the whole release machine runs end to end in ninety seconds on
//  a desk instead of ninety days on a calendar. Also runs the in-target
//  self-tests and lists any failure.
//
//  This file compiles only in DEBUG. Nothing in a release build can move
//  the clock.

#if DEBUG
struct TimeTravelView: View {
    @Bindable var estateEngine: EstateEngine
    let onClose: () -> Void

    @State private var simulated = Clocks.isSimulated
    @State private var report: SelfTest.Report?
    @State private var running = false

    var body: some View {
        NavigationStack {
            ZStack {
                SealTheme.ink.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Toggle("Use a simulated clock", isOn: $simulated)
                            .tint(.orange)
                            .onChange(of: simulated) { _, on in Clocks.setSimulated(on) }
                        Text("Now: \(Clocks.current.now.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(.title3, design: .monospaced)).foregroundStyle(.orange)
                        HStack {
                            ForEach([1, 7, 21, 30, 90], id: \.self) { days in
                                Button("+\(days)d") { Clocks.travel(days: Double(days)) }
                                    .buttonStyle(.bordered).tint(.orange)
                                    .disabled(!simulated)
                            }
                        }
                        Text("Advancing the clock re-evaluates every estate on this phone. To run the story: seal, travel 91 days, have a key holder's phone claim, travel 21 then 14, tap keys, combine. The owner opening the app at any point cancels.")
                            .font(.caption).foregroundStyle(.white.opacity(0.5)).fixedSize(horizontal: false, vertical: true)

                        Divider().overlay(.white.opacity(0.2))

                        Button {
                            running = true
                            Task {
                                report = SelfTest.runAll(SelfTestRegistry.suites)
                                running = false
                            }
                        } label: {
                            HStack {
                                if running { ProgressView().tint(SealTheme.ink) }
                                Text("Run the self-tests").frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.borderedProminent).tint(SealTheme.brass)
                        if let report {
                            Text(report.passed ? "\(report.checks) checks passed." : "\(report.failures.count) of \(report.checks) checks FAILED.")
                                .font(.headline).foregroundStyle(report.passed ? SealTheme.brass : .orange)
                            ForEach(report.failures) { f in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(f.suite) / \(f.name)").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                                    if !f.detail.isEmpty { Text(f.detail).font(.caption2).foregroundStyle(.white.opacity(0.6)) }
                                }
                            }
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(20)
                }
            }
            .navigationTitle("Time travel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: onClose).foregroundStyle(SealTheme.brass) } }
        }
        .preferredColorScheme(.dark)
    }
}
#endif
