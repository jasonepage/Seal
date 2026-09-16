// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

//  LetterSecretScan.swift
//  Seal
//
//  A SECRET TYPED INTO THE WRONG BOX.
//
//  The letter is shown in full the moment an envelope opens. A secret is
//  hidden behind a Face ID check and copied byte for byte. People paste a
//  recovery phrase into the letter, because the letter is the big box and it
//  is where they were already typing. Nothing stopped them.
//
//  This is a plain, deterministic check. No model, no network, nothing
//  leaves the phone, and it never changes a word on its own. It finds two
//  shapes: a run of words that are all in the BIP39 list (12, 15, 18, 21 or
//  24 is a standard phrase; anything from 12 up is flagged, because the
//  run can pick up an ordinary word on either side), and the common forms
//  of a private key. The editor offers one quiet line and one tap.
enum LetterSecretScan {

    enum Kind: Hashable {
        /// `count` words in a row, every one in the BIP39 English list.
        case seedPhrase(count: Int)
        case privateKey
    }

    struct Finding: Hashable, Identifiable {
        let kind: Kind
        /// The exact text in the letter, used to remove it.
        let original: String
        /// What goes into the secret: for a phrase, the words joined by
        /// single spaces (numbering and line breaks are not part of a
        /// phrase); for a key, the key exactly as typed.
        let value: String
        var id: String { value }

        var cardType: SealedCardType {
            switch kind {
            case .seedPhrase: .seedPhrase
            case .privateKey: .password
            }
        }

        var cardTitle: String {
            switch kind {
            case .seedPhrase: "Recovery phrase"
            case .privateKey: "Private key"
            }
        }

        /// The one line under the letter. Calm, plain, and it says the
        /// thing that matters: a letter is shown, a secret is hidden.
        var line: String {
            switch kind {
            case .seedPhrase(let count):
                return "Those \(Self.spelled(count)) words look like a recovery phrase. A letter is shown in full when it opens. A secret stays hidden until Seal checks their face. Move it?"
            case .privateKey:
                return "That looks like a private key. A letter is shown in full when it opens. A secret stays hidden until Seal checks their face. Move it?"
            }
        }

        private static func spelled(_ n: Int) -> String {
            let names = [12: "twelve", 15: "fifteen", 18: "eighteen", 21: "twenty-one", 24: "twenty-four"]
            return names[n] ?? String(n)
        }
    }

    static let minimumPhraseWords = 12

    /// Every finding in the letter, private keys first, then phrases.
    static func scan(_ letter: String) -> [Finding] {
        guard !letter.isEmpty else { return [] }
        var findings = privateKeys(in: letter)
        // A key is base58 or hex, never BIP39 words, so the two cannot
        // overlap and the phrase scan runs on the letter as it stands.
        findings.append(contentsOf: seedPhrases(in: letter))
        return findings
    }

    // MARK: - Recovery phrases

    /// Tokens are split on whitespace. A token that is only digits and
    /// punctuation (a list number like "1." or "7)") is skipped without
    /// breaking the run, so a numbered phrase is still one phrase. Any
    /// other token that is not a BIP39 word, after stripping punctuation
    /// and case, ends the run.
    static func seedPhrases(in letter: String) -> [Finding] {
        var findings: [Finding] = []
        var runWords: [String] = []
        var runStart: String.Index?
        var runEnd: String.Index?

        func close() {
            if runWords.count >= minimumPhraseWords, let s = runStart, let e = runEnd {
                findings.append(Finding(kind: .seedPhrase(count: runWords.count),
                                        original: String(letter[s..<e]),
                                        value: runWords.joined(separator: " ")))
            }
            runWords = []; runStart = nil; runEnd = nil
        }

        var index = letter.startIndex
        while index < letter.endIndex {
            // Skip whitespace.
            while index < letter.endIndex, letter[index].isWhitespace { index = letter.index(after: index) }
            guard index < letter.endIndex else { break }
            let tokenStart = index
            while index < letter.endIndex, !letter[index].isWhitespace { index = letter.index(after: index) }
            let token = letter[tokenStart..<index]

            let core = token.trimmingCharacters(in: .punctuationCharacters.union(.symbols)).lowercased()
            if core.isEmpty || core.allSatisfy(\.isNumber) {
                continue   // a list number, or bare punctuation: neither counts nor breaks
            }
            if bip39English.contains(core) {
                if runStart == nil { runStart = tokenStart }
                runWords.append(core)
                runEnd = index
            } else {
                close()
            }
        }
        close()
        return findings
    }

    // MARK: - Private keys

    /// The shapes people actually paste. Each is anchored to a word
    /// boundary so a long ordinary word cannot match.
    private static let keyPatterns: [String] = [
        // Extended private key (BIP32): "xprv" then base58, about 111 characters.
        #"\b[xyz]prv[1-9A-HJ-NP-Za-km-z]{100,120}\b"#,
        // Wallet import format: starts with 5, K or L, 51 or 52 base58 characters.
        #"\b[5KL][1-9A-HJ-NP-Za-km-z]{50,51}\b"#,
        // A raw 32-byte key as 64 hex characters, with or without 0x.
        #"\b(?:0x)?[0-9a-fA-F]{64}\b"#,
        // PEM: anything from BEGIN ... PRIVATE KEY to its END line.
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#,
    ]

    static func privateKeys(in letter: String) -> [Finding] {
        var findings: [Finding] = []
        for pattern in keyPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let whole = NSRange(letter.startIndex..<letter.endIndex, in: letter)
            for match in regex.matches(in: letter, range: whole) {
                guard let range = Range(match.range, in: letter) else { continue }
                let text = String(letter[range])
                findings.append(Finding(kind: .privateKey, original: text, value: text))
            }
        }
        return findings
    }

    // MARK: - Moving it

    /// The letter with the finding's text taken out, and the whitespace
    /// around the hole tidied so two paragraphs do not become one.
    static func removing(_ finding: Finding, from letter: String) -> String {
        guard let range = letter.range(of: finding.original) else { return letter }
        var out = letter
        out.replaceSubrange(range, with: "")
        // Collapse three or more line breaks left behind into two.
        while let r = out.range(of: "\n\n\n") { out.replaceSubrange(r, with: "\n\n") }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
