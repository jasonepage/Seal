// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import AVKit

//  VideoPlaySheet.swift
//  Seal
//
//  The video message, full screen, with the system controls. The bytes
//  are written to a temporary file for the player (AVPlayer wants a URL)
//  and removed when the sheet closes. Save writes the same bytes to the
//  phone's Photos, add-only, on a tap (MediaSaving).

struct VideoPlaySheet: View {
    let data: Data
    let onClose: () -> Void

    @State private var url: URL?
    @State private var player: AVPlayer?
    @State private var saved: String?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let player {
                    VideoPlayer(player: player)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    ProgressView().tint(SealTheme.brass)
                }
            }
            .navigationTitle("Video message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close", action: onClose).foregroundStyle(SealTheme.brass) }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            do { try await MediaSaving.saveVideo(data); saved = "Saved to your Photos." }
                            catch { self.error = error.localizedDescription }
                        }
                    } label: { Label("Save", systemImage: "square.and.arrow.down") }
                    .foregroundStyle(SealTheme.brass)
                }
            }
            .task {
                guard url == nil, let file = try? MediaSaving.tempFile(data, extension: "mov") else { return }
                url = file
                let p = AVPlayer(url: file)
                player = p
                p.play()
            }
            .onDisappear {
                player?.pause()
                if let url { try? FileManager.default.removeItem(at: url) }
            }
            .alert("Seal", isPresented: Binding(get: { saved != nil || error != nil },
                                                set: { if !$0 { saved = nil; error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(saved ?? error ?? "") }
        }
        .preferredColorScheme(.dark)
    }
}
