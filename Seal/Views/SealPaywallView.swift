// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

//  SealPaywallView.swift
//  Seal
//
//  THE ONE PAYMENT SHEET. Shown once, on the first seal, to the owner and
//  nobody else. It says what the money is for, what stays free, and the
//  price in the person's own currency. No countdown, no "most popular",
//  no comparison table. One price, one button, one way out.
//
//  Not brass. Paying is not a trust moment; the seal that follows is.
struct SealPaywallView: View {
    @Bindable var purchase: SealPurchase
    /// Called after a successful purchase or restore, so the caller can go
    /// straight on to the seal the person was in the middle of.
    let onUnlocked: () -> Void
    let onClose: () -> Void

    @State private var restoring = false

    var body: some View {
        NavigationStack {
            ZStack {
                SealTheme.ink.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        SealMark(size: 56, trust: false, pressOnAppear: false)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 8)
                        Text("One payment, then it is yours for good.")
                            .font(.system(.title2, design: .rounded, weight: .semibold))
                            .foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Sealing is the one thing Seal charges for. You pay once, the first time you seal. After that, every change and every new envelope seals for free, for as long as you live. There is no subscription and nothing to renew.")
                            .font(.callout).foregroundStyle(.white.opacity(0.8))
                            .fixedSize(horizontal: false, vertical: true)
                        VStack(alignment: .leading, spacing: 10) {
                            line("Writing envelopes is free.")
                            line("Holding a key for someone is free. The people you choose never pay.")
                            line("Opening an envelope written for you is free.")
                            line("Sealing again after a change is free.")
                        }
                        .padding(16)
                        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))

                        if let price = purchase.displayPrice {
                            Button {
                                Task {
                                    if await purchase.buy() { onUnlocked() }
                                }
                            } label: {
                                HStack {
                                    if purchase.isBuying { ProgressView().tint(SealTheme.ink) }
                                    Text("Pay \(price) and seal")
                                        .font(.system(.headline, design: .rounded))
                                }
                                .frame(maxWidth: .infinity).padding(.vertical, 8)
                            }
                            .buttonStyle(.borderedProminent).tint(.white)
                            .foregroundStyle(SealTheme.ink)
                            .disabled(purchase.isBuying)
                            .parentTapTarget(60)
                        } else if let error = purchase.loadError {
                            Text(error)
                                .font(.callout).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                            Button {
                                Task { await purchase.loadProduct() }
                            } label: {
                                Text("Try again").frame(maxWidth: .infinity).padding(.vertical, 6)
                            }
                            .buttonStyle(.bordered).tint(.white)
                            .parentTapTarget()
                        } else {
                            HStack {
                                ProgressView().tint(.white)
                                Text("Asking the App Store for the price.")
                                    .font(.callout).foregroundStyle(.white.opacity(0.6))
                            }
                            .frame(maxWidth: .infinity)
                            .task { await purchase.loadProduct() }
                        }

                        if let error = purchase.loadError, purchase.displayPrice != nil {
                            Text(error)
                                .font(.caption).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Button {
                            restoring = true
                            Task {
                                await purchase.restore()
                                restoring = false
                                if purchase.isUnlocked { onUnlocked() }
                            }
                        } label: {
                            HStack {
                                if restoring { ProgressView().tint(.white) }
                                Text("Already paid on another phone? Restore it")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                        .font(.callout).foregroundStyle(.white.opacity(0.6))
                        .disabled(restoring)
                        .parentTapTarget()

                        Text("Payment goes through Apple. Seal never sees your card. Your envelopes and your people stay on your phone whether you pay or not; only the seal waits.")
                            .font(.caption).foregroundStyle(.white.opacity(0.4))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(20)
                    .frame(maxWidth: 520).frame(maxWidth: .infinity)
                    .containerRelativeFrame(.horizontal)
                }
            }
            .navigationTitle("Seal it")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Not now", action: onClose).foregroundStyle(.white.opacity(0.7)) }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func line(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark").font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.7)).padding(.top, 3)
            Text(text).font(.callout).foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
