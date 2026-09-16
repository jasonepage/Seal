// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppIntents

//  CheckInIntent.swift
//  Seal
//
//  "CHECK IN WITH SEAL." Siri, the Shortcuts app, the Action button.
//
//  WHY IT OPENS THE APP instead of writing the heartbeat quietly in the
//  background. Three reasons, any one of which would be enough:
//
//    1. The heartbeat is signed by this phone's Secure Enclave key, which
//       is stored "when unlocked, this device only". A Siri request from a
//       locked phone could not sign it, and would have to fail or lie.
//    2. The engine that writes the log lives inside the running app. A
//       second copy of it, started in the background by the intent, would
//       race the app's own copy of the event log in the keychain.
//    3. PRODUCT.md section 7: stopping a release takes "Face ID at most".
//       If the app lock is on, that Face ID check is the gate. A background
//       heartbeat would go around it.
//
//  So the intent opens the app, and opening the app IS the heartbeat
//  (HomeView.refreshEverything runs on every foreground). The intent
//  leaves a flag so the home screen can say "you are checked in" out loud
//  instead of just quietly doing it. The person taps the Action button,
//  Seal comes up, one line confirms it, they put the phone down.

struct CheckInIntent: AppIntent {
    static var title: LocalizedStringResource = "Check in with Seal"
    static var description = IntentDescription("Opens Seal and shows you are still here. That is all a check-in is.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        CheckInRequest.flag()
        return .result()
    }
}

/// The phrases Siri and Shortcuts offer without any setup.
struct SealShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CheckInIntent(),
            phrases: [
                "Check in with \(.applicationName)",
                "\(.applicationName) check in",
                "Tell \(.applicationName) I am here",
            ],
            shortTitle: "Check in",
            systemImageName: "checkmark.seal.fill")
    }
}
