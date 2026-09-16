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
//  shapes: a run of words that are all on one recovery word list (every
//  BIP39 language, Trezor's SLIP39 list, and Monero's lists; anything from
//  the shortest real phrase up is flagged, because the run can pick up an
//  ordinary word on either side), and the common forms of a private key.
//  The editor offers one quiet line and one tap.
enum LetterSecretScan {

    /// Which kind of wallet writes its recovery words from a given list.
    enum Family: Hashable {
        /// Bitcoin Improvement Proposal 39: the 12 or 24 words almost every
        /// wallet uses, in ten languages.
        case bip39
        /// SatoshiLabs Improvement Proposal 39: a Trezor Shamir Backup
        /// share, 20 or 33 words from a 1,024 word list.
        case slip39
        /// Monero's own 1,626 word lists, 25 words (or 13). Old Electrum
        /// wallets used the English one too.
        case monero
    }

    /// One list the scan knows. Every file in Seal/Cards/Wordlists is one
    /// of these, and `all` is the only place they are named.
    struct Wordlist {
        let family: Family
        let words: Set<String>
        /// The shortest run worth mentioning. Set to the shortest real
        /// phrase for that family, so a run that could not be one is not.
        let minimum: Int
    }

    static let wordlists: [Wordlist] = [
        Wordlist(family: .bip39, words: bip39English, minimum: 12),
        Wordlist(family: .bip39, words: bip39Spanish, minimum: 12),
        Wordlist(family: .bip39, words: bip39French, minimum: 12),
        Wordlist(family: .bip39, words: bip39Italian, minimum: 12),
        Wordlist(family: .bip39, words: bip39Portuguese, minimum: 12),
        Wordlist(family: .bip39, words: bip39Czech, minimum: 12),
        Wordlist(family: .bip39, words: bip39Japanese, minimum: 12),
        Wordlist(family: .bip39, words: bip39Korean, minimum: 12),
        Wordlist(family: .bip39, words: bip39ChineseSimplified, minimum: 12),
        Wordlist(family: .bip39, words: bip39ChineseTraditional, minimum: 12),
        Wordlist(family: .slip39, words: slip39English, minimum: 20),
        Wordlist(family: .monero, words: moneroEnglish, minimum: 13),
        Wordlist(family: .monero, words: moneroSpanish, minimum: 13),
        Wordlist(family: .monero, words: moneroFrench, minimum: 13),
        Wordlist(family: .monero, words: moneroGerman, minimum: 13),
        Wordlist(family: .monero, words: moneroItalian, minimum: 13),
        Wordlist(family: .monero, words: moneroDutch, minimum: 13),
        Wordlist(family: .monero, words: moneroPortuguese, minimum: 13),
        Wordlist(family: .monero, words: moneroRussian, minimum: 13),
        Wordlist(family: .monero, words: moneroJapanese, minimum: 13),
        Wordlist(family: .monero, words: moneroChineseSimplified, minimum: 13),
        Wordlist(family: .monero, words: moneroEsperanto, minimum: 13),
        Wordlist(family: .monero, words: moneroLojban, minimum: 13),
    ]

    enum Kind: Hashable {
        /// `count` words in a row, every one on one list.
        case recoveryWords(count: Int, family: Family)
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
            case .recoveryWords: .seedPhrase
            case .privateKey: .password
            }
        }

        var cardTitle: String {
            switch kind {
            case .recoveryWords(_, .slip39): "Recovery share"
            case .recoveryWords: "Recovery phrase"
            case .privateKey: "Private key"
            }
        }

        /// The one line under the letter. Calm, plain, and it says the
        /// thing that matters: a letter is shown, a secret is hidden.
        var line: String {
            switch kind {
            case .recoveryWords(let count, let family):
                let what: String
                switch family {
                case .bip39: what = "a recovery phrase"
                case .slip39: what = "a recovery share, the kind a Trezor makes"
                case .monero: what = "a Monero recovery phrase"
                }
                return "Those \(Self.spelled(count)) words look like \(what). A letter is shown in full when it opens. A secret stays hidden until Seal checks their face. Move it?"
            case .privateKey:
                return "That looks like a private key. A letter is shown in full when it opens. A secret stays hidden until Seal checks their face. Move it?"
            }
        }

        private static func spelled(_ n: Int) -> String {
            let names = [12: "twelve", 13: "thirteen", 15: "fifteen", 18: "eighteen", 20: "twenty",
                         21: "twenty-one", 24: "twenty-four", 25: "twenty-five", 33: "thirty-three"]
            return names[n] ?? String(n)
        }
    }

    /// Every finding in the letter, private keys first, then phrases.
    static func scan(_ letter: String) -> [Finding] {
        guard !letter.isEmpty else { return [] }
        var findings = privateKeys(in: letter)
        // A key is base58 or hex, never a wordlist word, so the two cannot
        // overlap and the phrase scans run on the letter as it stands.
        findings.append(contentsOf: recoveryWords(in: letter))
        return findings
    }

    /// Every list, then one finding per stretch of text. Lists share words
    /// (English BIP39 and English Monero share about four hundred, and the
    /// Romance languages share more), so the same words can match twice.
    /// The longest run for a stretch wins and the rest are dropped, so the
    /// owner is asked once.
    static func recoveryWords(in letter: String) -> [Finding] {
        var all: [Finding] = []
        for list in wordlists {
            all.append(contentsOf: wordRuns(in: letter, list: list.words, minimum: list.minimum) {
                .recoveryWords(count: $0, family: list.family)
            })
        }
        var kept: [Finding] = []
        for finding in all.sorted(by: { $0.original.count > $1.original.count }) {
            let overlaps = kept.contains { $0.original.contains(finding.original) || finding.original.contains($0.original) }
            if !overlaps { kept.append(finding) }
        }
        return kept
    }

    // MARK: - Recovery phrases

    /// Tokens are split on whitespace. A token that is only digits and
    /// punctuation (a list number like "1." or "7)") is skipped without
    /// breaking the run, so a numbered phrase is still one phrase. Any
    /// other token that is not on the list, after stripping punctuation
    /// and case, ends the run. One walker, two lists.
    static func wordRuns(in letter: String, list: Set<String>, minimum: Int,
                         kind: (Int) -> Kind) -> [Finding] {
        var findings: [Finding] = []
        var runWords: [String] = []
        var runStart: String.Index?
        var runEnd: String.Index?

        func close() {
            if runWords.count >= minimum, let s = runStart, let e = runEnd {
                findings.append(Finding(kind: kind(runWords.count),
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

            // Composed (NFC) to match how the lists are stored, so an accent
            // typed as two key strokes still finds its word.
            let core = token.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
                .lowercased().precomposedStringWithCanonicalMapping
            if core.isEmpty || core.allSatisfy(\.isNumber) {
                continue   // a list number, or bare punctuation: neither counts nor breaks
            }
            if list.contains(core) {
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
