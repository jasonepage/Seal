// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AVFoundation
import SwiftUI

//  LetterReader.swift
//  Seal
//
//  "Read it to me" (1.3). The phone's own voice reads an opened letter out
//  loud, for somebody whose eyes are not what they were, or who simply
//  wants to hear it.
//
//  AVSpeechSynthesizer runs on the phone. Nothing is sent anywhere.
//
//  It reads the title and the letter, never the secrets. A password said
//  out loud is a password told to the whole room.
//
//  It stops when the screen closes, when the page changes, and the moment
//  the app leaves the foreground, so a locked phone is never still talking.

final class LetterReader: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    /// The page being read, or nil.
    @Published private(set) var readingID: String?
    private let synthesizer = AVSpeechSynthesizer()
    /// The utterance being spoken. A cancelled one reports back a moment
    /// later; without this check that late report would switch off the
    /// button for the next page, which is already reading.
    private var current: ObjectIdentifier?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func toggle(id: String, title: String, letter: String) {
        if readingID == id {
            stop()
            return
        }
        stop()
        let session = AVAudioSession.sharedInstance()
        // Playback, so it is heard with the ring switch on silent. Many
        // phones live there.
        try? session.setCategory(.playback, mode: .spokenAudio, options: .duckOthers)
        try? session.setActive(true)
        let text = title.isEmpty ? letter : "\(title).\n\n\(letter)"
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        // A little slower than the default: this is a letter, not a news
        // reader. Somebody who set their own voice and speed under
        // Accessibility, Spoken Content, gets theirs instead.
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
        utterance.prefersAssistiveTechnologySettings = true
        current = ObjectIdentifier(utterance)
        readingID = id
        synthesizer.speak(utterance)
    }

    func stop() {
        guard readingID != nil || synthesizer.isSpeaking else { return }
        current = nil
        readingID = nil
        synthesizer.stopSpeaking(at: .immediate)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func finished(_ token: ObjectIdentifier) {
        guard token == current else { return }
        current = nil
        readingID = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let token = ObjectIdentifier(utterance)
        Task { @MainActor in self.finished(token) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let token = ObjectIdentifier(utterance)
        Task { @MainActor in self.finished(token) }
    }
}
