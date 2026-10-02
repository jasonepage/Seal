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

    private var covers: [UIWindow] = []
    private var observer: NSObjectProtocol?

    /// Called once at launch (SealApp). UIKit posts this while the scene is
    /// going to the background, before the snapshot is taken; SwiftUI's
    /// scenePhase change is not promised to arrive in time. The scenePhase
    /// path below stays as a second chance, and is what lifts the cover.
    func install() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: UIScene.didEnterBackgroundNotification,
                                                          object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PrivacyShield.shared.raise() }
        }
    }

    func update(for phase: ScenePhase) {
        switch phase {
        case .background: raise()
        case .active: lift()
        default: break
        }
    }

    fileprivate func raise() {
        guard covers.isEmpty else { return }
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            let window = UIWindow(windowScene: scene)
            window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
            window.rootViewController = UIHostingController(rootView: PrivacyCover())
            window.isHidden = false
            covers.append(window)
        }
    }

    private func lift() {
        for window in covers { window.isHidden = true }
        covers.removeAll()
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
