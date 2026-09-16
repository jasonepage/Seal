// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import StoreKit
import os

//  SealPurchase.swift
//  Seal
//
//  THE ONE THING SEAL CHARGES FOR.
//
//  Decided 2026-09-16 (HANDOFF.md, Pricing): the app is free to install,
//  because key holders and recipients did not choose it and must never see
//  a price. The owner pays once, on the first tap of "Seal the envelopes".
//  Writing, meeting people and holding a key are free. Re-sealing after a
//  change is free forever. It is a one time purchase, never a subscription,
//  because a sealed estate that could break when a card expires is a
//  product that lies.
//
//  StoreKit 2, one non-consumable product. Apple keeps the receipt; this
//  phone asks Apple whether this Apple ID owns it. Nothing about the
//  purchase is written to the estate or the directory, so a key holder's
//  or recipient's phone never learns whether the owner paid, and a signed
//  record never depends on a store.
//
//  Fail closed on the purchase, fail open on the store: if the product
//  cannot be loaded (no network, the Paid Applications agreement not yet
//  signed in App Store Connect), the paywall says so and offers to try
//  again. It never pretends the seal is free, and it never charges twice.
@Observable
@MainActor
final class SealPurchase {

    /// The product identifier in App Store Connect. Non-consumable. The
    /// string is part of the store, not the code: change it here and there
    /// together or the sheet shows nothing to buy.
    static let productID = "io.github.jasonepage.Seal.lifetime"

    private static let log = Logger(subsystem: "io.github.jasonepage.Seal", category: "store")

    /// True once Apple says this Apple ID owns the product. Starts false
    /// and is settled by `refresh()` on launch, so the paywall is never
    /// shown to somebody who already paid, and never skipped for somebody
    /// who did not.
    private(set) var isUnlocked = false
    /// True until the first entitlement check has come back. The seal
    /// button waits on this rather than guessing.
    private(set) var isChecking = true
    private(set) var product: Product?
    private(set) var loadError: String?
    private(set) var isBuying = false

    private var updates: Task<Void, Never>?

    init() {
        // Purchases made on another device, refunds, and a purchase that
        // finished after the app was killed all arrive here.
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                if case .verified(let transaction) = result {
                    await transaction.finish()
                    await self.refresh()
                }
            }
        }
    }

    /// The price as the store shows it in the person's own currency, or
    /// nil until the product has loaded.
    var displayPrice: String? { product?.displayPrice }

    /// Ask Apple what this Apple ID owns, then load the product. Called on
    /// launch and after every purchase or restore.
    func refresh() async {
        defer { isChecking = false }
        var owned = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               transaction.productID == Self.productID,
               transaction.revocationDate == nil {
                owned = true
            }
        }
        isUnlocked = owned
        if product == nil { await loadProduct() }
    }

    func loadProduct() async {
        loadError = nil
        do {
            let products = try await Product.products(for: [Self.productID])
            guard let found = products.first else {
                loadError = "The App Store did not list the seal. If this is a new build, the product may not be set up yet."
                Self.log.error("store: product \(Self.productID, privacy: .public) not returned")
                return
            }
            product = found
        } catch {
            loadError = "The App Store did not answer. Check the connection and try again."
            Self.log.error("store: load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The system payment sheet. True when the purchase went through and
    /// the seal may proceed. False for a cancel, a pending family approval,
    /// or a failure, each with `loadError` set where there is something to
    /// say.
    func buy() async -> Bool {
        guard !isBuying else { return false }
        if product == nil { await loadProduct() }
        guard let product else { return false }
        isBuying = true
        defer { isBuying = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    loadError = "Apple could not verify the purchase. Nothing was charged. Try again."
                    return false
                }
                await transaction.finish()
                await refresh()
                return isUnlocked
            case .pending:
                // Ask to Buy: a family organiser has to approve. Not an
                // error, not a success. Transaction.updates delivers it.
                loadError = "The purchase is waiting for approval. Once it is approved, come back and tap Seal."
                return false
            case .userCancelled:
                return false
            @unknown default:
                return false
            }
        } catch {
            loadError = "The purchase did not go through. Nothing was charged. \(error.localizedDescription)"
            Self.log.error("store: purchase failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Restore on a new phone or after a reinstall. Apple's sync, then the
    /// same entitlement check as launch.
    func restore() async {
        loadError = nil
        do {
            try await AppStore.sync()
        } catch {
            loadError = "Could not reach the App Store to restore. \(error.localizedDescription)"
        }
        await refresh()
    }
}
