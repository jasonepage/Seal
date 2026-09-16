// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Speech
import AVFoundation
import os

//  Dictation.swift
//  Seal
//
//  TALKING INSTEAD OF TYPING, WITH THE VOICE STAYING HERE.
//
//  ============================================================
//  THE RULE OF THIS FILE:
//
//  `requiresOnDeviceRecognition = true` IS SET ON EVERY REQUEST, AND A
//  PHONE THAT CANNOT HONOUR IT GETS NO MICROPHONE BUTTON AT ALL.
//
//  Not "prefer on device". Not "fall back to the server if the phone is
//  slow". If `supportsOnDeviceRecognition` is false for this locale on this
//  phone, dictation is off and the person types. Same fail-closed rule as
//  the interview's drafter (InterviewDrafting.swift): the whole product is
//  one promise about secrets, and a feature that hears every password and
//  sends it anywhere would end that promise whatever the fine print said.
//  ============================================================
//
//  WHY THIS EXISTS AT ALL, given the keyboard already has a microphone key.
//  Because Seal cannot see what that key does. The system keyboard's
//  dictation is Apple's, its behaviour changes with the language, the
//  hardware and settings Seal does not control, and there is no public way
//  to remove that key from a text field. Meanwhile the interview's first
//  screen promises, flatly, that nothing typed there leaves the phone. This
//  is the microphone Seal can actually make that promise about, put next to
//  the box so somebody reaches for this one instead.
//
//  And because the product needs it. docs/PRODUCT.md section 11 describes
//  the run this is all built for: "It asks what she has never said to her.
//  She TALKS for two minutes." Nobody types two minutes of the hardest
//  thing they have ever said.
//
//  WHY NOT WHISPER. whisper.cpp plus a CoreML model means a Swift package
//  or an XCFramework, which means editing Seal.xcodeproj, which is off
//  limits, and 40 to 150MB of model in the bundle. SFSpeechRecognizer is a
//  system framework, needs no project change, and is the engine iOS
//  dictation itself used for years.
//
//  WHY NOT SpeechAnalyzer / SpeechTranscriber (iOS 26). Better, and the
//  right thing later. It is left out on purpose today: this tree has not
//  been compiled once, it already carries one uncertain new API surface in
//  FoundationModels, and a second one doubles the hand fixing before
//  anything runs. The seam is `Engine` below; adding a transcriber case
//  touches nothing else.
@Observable
final class Dictation {

    enum State: Equatable {
        case idle
        case starting
        case listening
        /// Off, with the plain reason. The caller shows this and nothing else.
        case off(String)
    }

    /// Which engine transcribed. One case today, see the note above.
    enum Engine { case onDeviceSpeechRecognizer }

    private static let log = Logger(subsystem: "io.github.jasonepage.Seal", category: "dictation")

    private(set) var state: State = .idle

    /// Segments the recognizer has finalised.
    private(set) var committed = ""
    /// The segment still being revised as they speak.
    private(set) var partial = ""

    /// Everything heard in this session.
    var transcript: String {
        let joined = committed + partial
        return joined.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isListening: Bool { state == .listening || state == .starting }

    private let recognizer = SFSpeechRecognizer(locale: Locale.current)
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// Set while stop() is tearing down, so a late callback cannot restart us.
    private var stopping = false

    // MARK: - Can this phone do it at all

    /// Cheap synchronous check for whether to draw the button. It does NOT
    /// ask for permission; that happens on the first tap, because a
    /// permission sheet before anybody asked for the microphone is how you
    /// teach somebody to say no.
    static var isSupportedOnThisPhone: Bool {
        guard let r = SFSpeechRecognizer(locale: Locale.current) else { return false }
        return r.supportsOnDeviceRecognition
    }

    // MARK: - Start and stop

    func start() async {
        guard !isListening else { return }
        stopping = false
        state = .starting

        guard let recognizer, recognizer.supportsOnDeviceRecognition else {
            state = .off("This phone can only do this by sending your voice away, so Seal keeps it turned off. Please type instead.")
            return
        }
        guard recognizer.isAvailable else {
            state = .off("Listening is not ready on this phone right now. Please type instead.")
            return
        }
        guard await requestSpeechPermission() else {
            state = .off("Seal needs your permission to turn speech into words. You can turn it on in Settings, under Seal.")
            return
        }
        guard await requestMicrophonePermission() else {
            state = .off("Seal needs your permission to use the microphone. You can turn it on in Settings, under Seal.")
            return
        }

        committed = ""
        partial = ""
        do {
            try beginSession()
            try beginTask(on: recognizer)
            state = .listening
        } catch {
            Self.log.error("start failed: \(error.localizedDescription, privacy: .public)")
            tearDown()
            state = .off("Seal could not start listening. Please type instead.")
        }
    }

    func stop() {
        guard state != .idle else { return }
        stopping = true
        tearDown()
        // Whatever was still being revised counts as said.
        if !partial.isEmpty {
            committed = appended(committed, partial)
            partial = ""
        }
        state = .idle
    }

    // MARK: - The audio and the task

    private func beginSession() throws {
        let session = AVAudioSession.sharedInstance()
        // .measurement turns off the processing meant for phone calls, which
        // is what the speech engine wants. duckOthers so a podcast playing in
        // the kitchen goes quiet rather than being transcribed.
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func beginTask(on recognizer: SFSpeechRecognizer) throws {
        let request = SFSpeechAudioBufferRecognitionRequest()
        // THE LINE. Everything else in this file is arrangements around it.
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        try engine.start()

        // The handler arrives on an arbitrary queue. Only Strings and Bools
        // cross back to the main actor, never the result object itself.
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let heard = result?.bestTranscription.formattedString
            let done = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor [weak self] in
                self?.absorb(heard, isFinal: done, failed: failed)
            }
        }
    }

    /// A long answer is the point of this feature, and the recogniser
    /// finalises on its own after a pause or a stretch of speech. When that
    /// happens while the person is still talking, the finished words are
    /// banked and a FRESH task starts on the same audio, so two minutes of
    /// rambling does not stop at the first natural break.
    private func absorb(_ heard: String?, isFinal: Bool, failed: Bool) {
        guard !stopping else { return }
        if let heard { partial = heard }

        guard isFinal || failed else { return }
        if !partial.isEmpty {
            committed = appended(committed, partial)
            partial = ""
        }
        guard state == .listening, let recognizer else { return }

        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        do {
            try beginTask(on: recognizer)
        } catch {
            Self.log.error("could not continue listening: \(error.localizedDescription, privacy: .public)")
            tearDown()
            state = .idle
        }
    }

    private func tearDown() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func appended(_ base: String, _ next: String) -> String {
        let trimmed = next.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return base }
        guard !base.isEmpty else { return trimmed }
        return base.hasSuffix(" ") ? base + trimmed : base + " " + trimmed
    }

    // MARK: - Permission

    private func requestSpeechPermission() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .denied, .restricted: return false
        default:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        }
    }

    private func requestMicrophonePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }
}
