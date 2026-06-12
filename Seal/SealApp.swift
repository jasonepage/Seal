//
//  SealApp.swift
//  Seal
//

import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Posted whenever a push arrives — HomeView listens and refreshes chats.
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

    /// Foreground pushes: refresh silently, no banner — the open chat updates live.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        NotificationCenter.default.post(name: Self.messageArrived, object: nil)
        return []
    }
}

@main
struct SealApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // FR-22: must run before ContentView creates the stores.
        DemoFixtures.prepare()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
