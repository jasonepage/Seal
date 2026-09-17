// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

//  CapsuleExportSheet.swift
//  Seal
//
//  Builds the capsule (Estate/Capsule.swift) and hands it to the share
//  sheet, so it lands in Files, on a drive, or in an email to the family's
//  lawyer. The whole promise is that this file outlives the company.

struct CapsuleExportSheet: View {
    let estateID: String
    @Bindable var estateEngine: EstateEngine
    let onClose: () -> Void

    @State private var includeContent = false
    @State private var building = false
    @State private var fileURL: URL?
    @State private var error: String?

    private var isOwner: Bool { estateEngine.estate?.id == estateID }

    var body: some View {
        NavigationStack {
            ZStack {
                SealTheme.ink.ignoresSafeArea()
                // A ScrollView, because with Bigger text on the paragraphs
                // pushed the Build button off the bottom of a small phone
                // and there was no way to reach it.
                ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("A copy you keep").font(.system(.title3, design: .rounded, weight: .semibold)).foregroundStyle(.white)
                    Text("One file with the whole signed record, every key share as it was wrapped, the encrypted key tables, and every public key needed to check it. Nothing in it is readable without the key holders' keys. It verifies with a small script and no Seal, no Apple and no account: tools/verify_capsule.py in the Seal repository.")
                        .font(.callout).foregroundStyle(.white.opacity(0.75)).fixedSize(horizontal: false, vertical: true)
                    if isOwner {
                        Toggle("Include the encrypted envelopes themselves", isOn: $includeContent).tint(SealTheme.brass).foregroundStyle(.white)
                        Text("Larger, but then the file alone is enough to open the envelopes after a release. Still encrypted. Keep it somewhere your key holders can reach.")
                            .font(.caption).foregroundStyle(.white.opacity(0.5)).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("As a key holder you export the record and the wrapped shares. The envelopes themselves are not yours to carry and are not in this file.")
                            .font(.caption).foregroundStyle(.white.opacity(0.5)).fixedSize(horizontal: false, vertical: true)
                    }
                    Button {
                        Task { await build() }
                    } label: {
                        HStack {
                            if building { ProgressView().tint(SealTheme.ink) }
                            Text(fileURL == nil ? "Build the file" : "Build again").frame(maxWidth: .infinity)
                        }
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent).tint(SealTheme.brass)
                    .disabled(building || DemoFixtures.isActive)
                    .parentTapTarget(60)
                    if let fileURL {
                        ShareLink(item: fileURL) {
                            Label("Save or send it", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity).padding(.vertical, 6)
                        }
                        .buttonStyle(.bordered).tint(.white)
                        .parentTapTarget(60)
                        Text(fileURL.lastPathComponent).font(.caption2).foregroundStyle(.white.opacity(0.4))
                    }
                    if let error { Text(error).font(.callout).foregroundStyle(.orange) }
                }
                .padding(20)
                .frame(maxWidth: 520).frame(maxWidth: .infinity)
                .containerRelativeFrame(.horizontal)
                }
            }
            .navigationTitle("Capsule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: onClose).foregroundStyle(SealTheme.brass) } }
        }
        .preferredColorScheme(.dark)
    }

    private func build() async {
        building = true
        defer { building = false }
        do {
            let data = try await CapsuleBuilder.build(estateID: estateID, engine: estateEngine,
                                                      sync: estateEngine.sync, includeContent: includeContent)
            let stamp = Int(estateEngine.now.timeIntervalSince1970)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("seal-capsule-\(estateID.prefix(8))-\(stamp).json")
            try data.write(to: url, options: .atomic)
            fileURL = url
        } catch {
            self.error = error.localizedDescription
        }
    }
}
