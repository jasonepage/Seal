// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

//  SettingRow.swift
//  Seal
//
//  A SETTING IS A TITLE, A SWITCH, AND A LINE. THE PARAGRAPH IS OPTIONAL.
//
//  Every explanation in this app was written to be read aloud to a parent,
//  which is right, and then every one of them was left standing permanently
//  on the screen, which turned a list of things you can change into a
//  document. Five lines about timestamp authorities do not belong in front of
//  somebody who came here to turn on Face ID.
//
//  So: a short line always, and an (i) that opens the rest in place for the
//  person who wants it. Nothing is hidden, because the button is right there
//  and the sentence it opens is the same sentence as before. It is the
//  difference between a screen that answers a question and a screen that
//  lectures.
//
//  RULE OF THUMB. If the summary runs past about seven words it is not a
//  summary, it is the detail, and it belongs behind the button.

struct SettingRow: View {
    let icon: String
    let tint: Color
    let title: String
    /// One short line, always on screen.
    let summary: String
    /// The long version, behind the info button. nil means no button.
    var detail: String? = nil
    @Binding var isOn: Bool
    let switchTint: Color

    @State private var showDetail = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if dynamicTypeSize.isAccessibilitySize {
                // At accessibility sizes a row and a switch do not fit beside
                // each other, so the switch drops below the label.
                label
                HStack {
                    infoButton
                    Spacer()
                    toggle
                }
            } else {
                HStack(spacing: 12) {
                    label
                    infoButton
                    toggle
                }
            }

            if showDetail, let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .frame(minHeight: 52)
        .padding(16)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 24)
    }

    private var label: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.9))
                Text(summary)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var infoButton: some View {
        if detail != nil {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { showDetail.toggle() }
            } label: {
                Image(systemName: showDetail ? "info.circle.fill" : "info.circle")
                    .foregroundStyle(.white.opacity(showDetail ? 0.8 : 0.4))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showDetail ? "Hide the explanation of \(title)" : "Explain \(title)")
        }
    }

    private var toggle: some View {
        Toggle(title, isOn: $isOn)
            .labelsHidden()
            .tint(switchTint)
    }
}

/// A card that stays shut until somebody asks. For the material that is true,
/// checkable and of no use to almost anybody: key hashes, sync status, device
/// endorsement. It is evidence, not a setting, and it should not be the first
/// thing under a heading.
struct DisclosureCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { open.toggle() }
            } label: {
                HStack {
                    Text(title)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.75))
                    Spacer()
                    Image(systemName: open ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .buttonStyle(.plain)
            .frame(minHeight: 44)

            if open {
                content()
                    .transition(.opacity)
            }
        }
        .padding(16)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 24)
    }
}
