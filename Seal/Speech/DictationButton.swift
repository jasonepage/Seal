// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

//  DictationButton.swift
//  Seal
//
//  THE MICROPHONE SEAL CAN VOUCH FOR. One row that sits under a text box
//  and appends what somebody says to what is already in it.
//
//  It draws NOTHING on a phone that cannot transcribe on device
//  (Dictation.isSupportedOnThisPhone). No greyed out button, no "not
//  available on this device" row. A control that cannot be used is clutter,
//  and a promise-shaped control that cannot be used is worse.
//
//  Colour: no brass. Brass marks a trust moment (docs/GOTCHAS.md house
//  rules) and talking into a phone is not one. Orange while listening,
//  matching the voice recorder in the envelope editor, because orange in
//  this app means something is happening right now.
struct DictationButton: View {

    /// The field this appends to. What is already there is kept.
    @Binding var text: String
    /// Shown under the button when idle. The promise is the point of the
    /// button, so it is said every time rather than hidden in a help screen.
    var promise = "Your voice stays on this phone."

    @State private var dictation = Dictation()
    /// What was in the field when listening started, so a long answer grows
    /// from it instead of replacing it.
    @State private var base = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if Dictation.isSupportedOnThisPhone {
                VStack(alignment: .leading, spacing: 8) {
                    button
                    if case .off(let reason) = dictation.state {
                        Text(reason)
                            .font(.footnote)
                            .foregroundStyle(.orange.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)
                    } else if !dictation.isListening {
                        Text(promise)
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.45))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .onChange(of: dictation.transcript) { _, heard in
            guard dictation.isListening else { return }
            text = joined(base, heard)
        }
        .onDisappear { dictation.stop() }
    }

    private var button: some View {
        Button {
            if dictation.isListening {
                dictation.stop()
            } else {
                base = text
                Task { await dictation.start() }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: dictation.isListening ? "stop.circle.fill" : "mic.fill")
                    .font(.title3)
                    .foregroundStyle(dictation.isListening ? .orange : .white.opacity(0.75))
                    .symbolEffect(.pulse, isActive: dictation.isListening && !reduceMotion)
                Text(dictation.isListening ? "Listening. Tap when you are done." : "Talk instead of typing")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(dictation.isListening ? .orange : .white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(dictation.isListening ? Color.orange.opacity(0.14) : Color.white.opacity(0.06)))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(dictation.isListening ? Color.orange.opacity(0.55) : Color.clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .parentTapTarget()
        .accessibilityLabel(dictation.isListening
                            ? "Stop listening"
                            : "Talk instead of typing. Your voice stays on this phone.")
    }

    /// Keep what was typed, add what was said, one space between.
    private func joined(_ base: String, _ heard: String) -> String {
        guard !heard.isEmpty else { return base }
        guard !base.isEmpty else { return heard }
        return base.hasSuffix(" ") || base.hasSuffix("\n") ? base + heard : base + " " + heard
    }
}
