// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

//  SealButtonStyle.swift
//  Seal
//
//  TWO BUTTON LOOKS, WITH A DISABLED STATE YOU CAN STILL READ.
//
//  The stock `.borderedProminent` and `.bordered` styles show a disabled
//  button by fading it toward whatever is behind it. On the ink background
//  that turned both registration buttons into grey shapes on a grey field,
//  with grey labels, and nothing on screen said why they were off.
//
//  These two styles set every colour themselves and give the disabled state
//  its own treatment: dimmer, but still a filled shape with a border and a
//  label you can read at arm's length. Half the people using this are over
//  sixty and the room may be bright.
//
//  The environment has to be read inside a nested view, not on the style
//  itself. A ButtonStyle is not part of the view tree, so an @Environment
//  property on the style reads the default value and never changes.
//
//  DO NOT name that nested view `Body`. ButtonStyle already has an
//  associated type called Body, a nested type of that name is taken as the
//  witness for it, and a private one is then less accessible than the style
//  itself, which fails the conformance. It is called `StyleBody` for that
//  reason and no other.

struct SealPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration)
    }

    private struct StyleBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.headline)
                .foregroundStyle(isEnabled ? SealTheme.ink : Color.white.opacity(0.6))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(isEnabled ? SealTheme.brass : SealTheme.brass.opacity(0.20))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(SealTheme.brass.opacity(isEnabled ? 0 : 0.5), lineWidth: 1)
                )
                .opacity(configuration.isPressed ? 0.85 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

struct SealSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration)
    }

    private struct StyleBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.headline)
                .foregroundStyle(Color.white.opacity(isEnabled ? 0.95 : 0.5))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(isEnabled ? 0.12 : 0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(isEnabled ? 0.40 : 0.20), lineWidth: 1)
                )
                .opacity(configuration.isPressed ? 0.85 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}
