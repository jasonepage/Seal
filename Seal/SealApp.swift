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

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        NotificationCenter.default.post(name: Self.messageArrived, object: nil)
        return .newData
    }

    /// Foreground pushes: refresh the open chat live AND surface a banner, so
    /// activity in OTHER chats is noticeable while the app is open (the single
    /// most-requested gap, previously all foreground banners were suppressed).
    /// TODO: suppress the banner when the user is actively viewing that chat
    /// (needs the group id in the push payload via desiredKeys).
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
        }
    }
}
