import Foundation
import UserNotifications
import os

//  CustodianNotices.swift
//  Seal
//
//  THE NOTIFICATION A KEY HOLDER ACTUALLY NEEDS.
//
//  CloudKit's push carries a fixed string chosen before anybody is invited,
//  so it can never say "Karen has been quiet past her limit." It also fires
//  on every event, and the owner writes a heartbeat event every time they
//  open the app, which is the point of the product. So the CloudKit push is
//  silent now (EstateDirectory.ensureEstateSubscription) and does one job:
//  wake the phone. This file is the other half. It runs after the refresh,
//  looks at where each guarded estate now stands, and posts a LOCAL
//  notification only when that has actually moved to something worth saying.
//
//  What it never does: notify on a heartbeat, notify twice for the same
//  state, notify about "all quiet", or notify in demo mode. A key holder
//  hears from this app a handful of times in ten years, and every one of
//  those times something real happened.
//
//  The last state it told somebody about is kept per identity in the
//  keychain, like the rest of the local state, and wiped on sign out
//  (ContentView.wipeLocalAndEngines). A phone that signs in fresh and finds
//  a claim already open is told about it once, which is right: it is news
//  to that phone.
enum CustodianNotices {

    private static let log = Logger(subsystem: "io.github.jasonepage.Seal", category: "notices")

    private static func key(_ ownerHash: String) -> String { "seal.notices.\(ownerHash)" }

    /// estateID to the raw value of the last state this phone announced.
    static func lastAnnounced(ownerHash: String) -> [String: String] {
        guard let data = KeychainStore.load(key(ownerHash)),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return map
    }

    private static func save(_ map: [String: String], ownerHash: String) {
        if let data = try? JSONEncoder().encode(map) {
            KeychainStore.save(data, for: key(ownerHash))
        }
    }

    static func wipe(ownerHash: String) { KeychainStore.delete(key(ownerHash)) }

    // MARK: - The line

    /// What to say, or nil for a state nobody needs waking for. Written to
    /// be read on a lock screen by somebody over sixty who has not thought
    /// about this app in four years, so it names the person first and says
    /// what to do second.
    static func line(for state: ReleaseState, guarded: GuardedEstate) -> String? {
        let name = guarded.ownerName.isEmpty ? "Someone you hold a key for" : guarded.ownerName
        switch state {
        case .active, .cancelled, .grace:
            // Nothing is being asked of them, so nothing is said. Grace is a
            // quiet period between the warnings and the keys; the claim was
            // already announced when it opened.
            return nil
        case .overdue:
            return guarded.isCustodian
                ? "\(name) has not opened Seal in a long time. If you believe they are gone, you can start a claim."
                : "\(name) has not opened Seal in a long time. The key holders have been told."
        case .warning:
            return "A claim has been started for \(name). They are being warned every day, and one tap from them stops it."
        case .claimOpen:
            return guarded.isCustodian
                ? "The warnings for \(name) are over. Keys can be tapped now, and yours is one of them."
                : "The warnings for \(name) are over. Keys can be tapped now."
        case .objected:
            return "A key holder has objected to the claim for \(name). Nothing moves while the objection stands."
        case .authorized:
            return "Enough keys have been tapped for \(name). The envelopes can be opened now."
        case .released:
            return guarded.isRecipient
                ? "\(name)'s envelopes have opened. Yours is waiting for you in Seal."
                : "\(name)'s envelopes have opened for the people they were written for."
        }
    }

    // MARK: - Posting

    /// Called after every refresh of the guarded estates.
    static func post(_ entries: [(guarded: GuardedEstate, state: ReleaseState?)],
                     ownerHash: String) async {
        guard !DemoFixtures.isActive, !entries.isEmpty else { return }

        var announced = lastAnnounced(ownerHash: ownerHash)
        var moved = false
        var pending: [(String, String)] = []   // (notification id, body)

        for entry in entries {
            guard let state = entry.state else { continue }
            let id = entry.guarded.estateID
            guard announced[id] != state.rawValue else { continue }
            announced[id] = state.rawValue
            moved = true
            guard let body = line(for: state, guarded: entry.guarded) else { continue }
            pending.append(("seal.notice.\(id).\(state.rawValue)", body))
        }

        // The record is written FIRST and once. If delivery fails, or the
        // person has notifications off, the state is still marked as told,
        // so a phone that refreshes six times an hour cannot turn one event
        // into six notifications the next time permission is granted.
        if moved { save(announced, ownerHash: ownerHash) }
        guard !pending.isEmpty else { return }

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else {
            log.info("notices: \(pending.count, privacy: .public) held back, notifications are not allowed")
            return
        }

        for (id, body) in pending {
            let content = UNMutableNotificationContent()
            content.title = "Seal"
            content.body = body
            content.sound = .default
            // Correct for "keys can be tapped now", and a NO-OP today: the
            // level needs com.apple.developer.usernotifications.time-sensitive
            // in Seal.entitlements plus the capability on the provisioning
            // profile, and neither is there. iOS quietly downgrades it to
            // .active rather than failing. Left in so that adding the
            // capability is the only step, and written down so nobody reads
            // this line as something that already works.
            content.interruptionLevel = .timeSensitive
            // nil trigger: deliver now, including from a background wake.
            let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
            do {
                try await center.add(request)
                log.info("notices: posted \(id, privacy: .public)")
            } catch {
                log.error("notices: could not post \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
