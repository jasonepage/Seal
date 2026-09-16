// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//
//  SealApp.swift
//  Seal
//

import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Posted whenever a push arrives, HomeView listens and refreshes chats.
    static let messageArrived = Notification.Name("seal.messageArrived")

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    // The completion handler form, not the async one: the async variant
    // carries the non-Sendable userInfo dictionary across an isolation
    // boundary and the compiler said so on every build. Nothing here reads
    // the payload; the push only wakes the phone (EstateDirectory).
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        NotificationCenter.default.post(name: Self.messageArrived, object: nil)
        completionHandler(.newData)
    }

    /// A notification arriving while the app is open: refresh, and still
    /// show the banner. The only notifications Seal posts are the ones a
    /// person must not miss (CustodianNotices, OwnerNotices), so there is
    /// no case for hiding one because the app happens to be in front.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        NotificationCenter.default.post(name: Self.messageArrived, object: nil)
        return [.banner, .sound, .list]
    }

    // APNs registration diagnostics, surfaced for triaging "push didn't work"
    // (HANDOFF). A failure here means CloudKit can't deliver via APNs at all.
    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        NSLog("Seal: APNs registered (%d-byte token)", deviceToken.count)
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NSLog("Seal: APNs registration FAILED: %@", error.localizedDescription)
    }
}

@main
struct SealApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    /// The one in-app purchase, alive for the whole app so the entitlement
    /// check happens once at launch and the transaction listener never
    /// goes away. Read with @Environment(SealPurchase.self).
    @State private var purchase = SealPurchase()

    init() {
        // FR-22: must run before ContentView creates the stores.
        DemoFixtures.prepare()
        // DEBUG only: the in-target test suites (Seal/SelfTest). Asserts on
        // any failure so a broken crypto or state machine change cannot be
        // missed by a developer running the app.
        SelfTest.runAtLaunchIfDebug()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(purchase)
                .task { await purchase.refresh() }
        }
    }
}
