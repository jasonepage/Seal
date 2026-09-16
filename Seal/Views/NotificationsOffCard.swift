// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import UserNotifications

//  NotificationsOffCard.swift
//  Seal
//
//  THE ONE SETTING THAT BREAKS THE PRODUCT QUIETLY.
//
//  Every message Seal ever sends a person is a notification: "Karen has
//  not opened Seal in a long time", "keys can be tapped now", and the
//  owner's own "open the app when you have a moment". A key holder who
//  tapped Don't Allow on day one, years before any of it mattered, hears
//  none of it, and nothing in the app said so. The commit that made the
//  estate push silent put it plainly: a key holder with notifications off
//  is the one person this product cannot afford to lose.
//
//  This card appears on the home screen only when it is true and only
//  when it matters: notifications are denied, and this phone either owns
//  a sealed estate or holds a part in somebody else's. One tap opens the
//  system settings page for Seal. Orange: it is a repair, not a trust
//  moment. It re-checks every time the app comes to the front, so it goes
//  away the moment the switch is flipped.
struct NotificationsOffCard: View {
    /// True when this phone has something to be told about.
    let matters: Bool

    @State private var denied = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if denied && matters {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Seal cannot reach you.", systemImage: "bell.slash.fill")
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                        .foregroundStyle(.orange)
                    Text("Notifications for Seal are turned off on this phone. Everything Seal ever needs to tell you comes as a notification: that someone has gone quiet, that a key is needed, or a gentle reminder to open the app. With them off, you find out only if you happen to open Seal.")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Text("Turn them on in Settings")
                            .font(.system(.headline, design: .rounded))
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent).tint(.orange)
                    .parentTapTarget(60)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 20))
                .padding(.horizontal, 20)
            }
        }
        .task { await check() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await check() } }
        }
    }

    private func check() async {
        guard !DemoFixtures.isActive else { denied = false; return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        denied = settings.authorizationStatus == .denied
    }
}
