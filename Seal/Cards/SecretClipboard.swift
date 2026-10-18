// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import UIKit
import UniformTypeIdentifiers

//  SecretClipboard.swift
//  Seal
//
//  THE ONE WAY A SECRET GOES TO THE CLIPBOARD. The recipient's reveal
//  screen and the owner's Passwords list both copy through here, so the
//  rules cannot drift apart:
//
//    - this phone only: no Universal Clipboard to a Mac or an iPad;
//    - the system clears it by itself after `SealedCard.clipboardLifetime`,
//      because a seed phrase left in the clipboard is readable by the next
//      app that asks (audit, medium);
//    - the confirmation reads back what actually landed and shows its ends,
//      so a swapped string shows up as ends that do not match the card.

enum SecretClipboard {
    /// Copies the card's exact value and returns the line to show.
    @MainActor
    static func copy(_ card: SealedCard) -> String {
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: card.value]],
            options: [.localOnly: true,
                      .expirationDate: Date().addingTimeInterval(SealedCard.clipboardLifetime)])
        guard let back = UIPasteboard.general.string else {
            return "Copied, but the clipboard would not confirm what it holds. Check before you paste."
        }
        return back == card.value
            ? SealedCard.copyConfirmation(for: back) + " The clipboard clears itself in \(Int(SealedCard.clipboardLifetime)) seconds."
            : "Something changed the clipboard between the copy and the check. Do not paste it."
    }
}
