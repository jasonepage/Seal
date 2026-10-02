// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import UIKit

//  PrivacyShield.swift
//  Seal
//
//  THE APP SWITCHER SEES A BLANK SEAL, NOT A SECRET (audit, medium).
//
//  iOS photographs the app as it goes to the background and shows that
//  picture in the app switcher. Before this, the picture was whatever was
//  open: a letter, a password, a seed phrase.
//
//  A window, not a SwiftUI overlay: an overlay on the root view sits UNDER
//  every sheet, and the reveal and the editors are sheets. A window at
//  alert level sits over all of them.
//
//  Raised on `.background`, which is where Apple says to hide sensitive
//  content before the snapshot. NOT on `.inactive`: the app also goes
//  inactive behind Face ID, the passkey and security key sheets, and the
//  App Store payment sheet, and a window over those could hide the very
//  sheet the person has to use. The cost of this choice: while the app
//  switcher is open the card can still show the live screen, until the
//  app actually leaves the front.

@MainActor
final class PrivacyShield {
    static let shared = PrivacyShield()

    /// One cover per window scene. On iPad Seal can have several windows,
    /// and one going to the background must never cover another that is
    /// still in use (review of this fix).
    private var covers: [ObjectIdentifier: UIWindow] = [:]
    private var observers: [NSObjectProtocol] = []

    /// Called once at launch (SealApp). UIKit posts these per scene, and
    /// posts the background one before the snapshot is taken; SwiftUI's
    /// scenePhase change is not promised to arrive in time. Queue `.main`
    /// runs the block at once on the main thread.
    func install() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIScene.didEnterBackgroundNotification,
                                            object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                if let scene = note.object as? UIWindowScene { PrivacyShield.shared.raise(over: scene) }
            }
        })
        observers.append(center.addObserver(forName: UIScene.willEnterForegroundNotification,
                                            object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                if let scene = note.object as? UIWindowScene { PrivacyShield.shared.lift(from: scene) }
            }
        })
        observers.append(center.addObserver(forName: UIScene.didDisconnectNotification,
                                            object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                if let scene = note.object as? UIWindowScene { PrivacyShield.shared.lift(from: scene) }
            }
        })
    }

    /// The SwiftUI path (SealApp), a second chance either way. On
    /// background it only covers; on active it only uncovers the scenes
    /// that are not in the background. It never undoes what UIKit just did.
    func update(for phase: ScenePhase) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        switch phase {
        case .background:
            for scene in scenes where scene.activationState == .background { raise(over: scene) }
        case .active:
            for scene in scenes where scene.activationState != .background { lift(from: scene) }
        default:
            break
        }
    }

    fileprivate func raise(over scene: UIWindowScene) {
        let key = ObjectIdentifier(scene)
        guard covers[key] == nil else { return }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
        window.rootViewController = UIHostingController(rootView: PrivacyCover())
        window.isHidden = false
        covers[key] = window
    }

    fileprivate func lift(from scene: UIWindowScene) {
        covers.removeValue(forKey: ObjectIdentifier(scene))?.isHidden = true
    }
}

private struct PrivacyCover: View {
    var body: some View {
        ZStack {
            SealTheme.ink.ignoresSafeArea()
            Image(systemName: "lock.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(SealTheme.silver)
                .accessibilityLabel("Seal is hidden until you come back to it.")
        }
    }
}
