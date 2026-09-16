// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

//  FirstSteps.swift
//  Seal
//
//  "WHAT TO DO FIRST."
//
//  A grieving family does not need a pile of passwords. They need to know
//  what to do first. So an envelope can carry a short ordered list the
//  owner fills in: "1. Call Mike at the credit union. 2. The car title is
//  in the blue folder in the garage. 3. Cancel the gym membership."
//
//  Where it lives: inside `Envelope`, and inside `Envelope.Payload`, so it
//  is sealed under the same envelope content key as the letter and the
//  secrets. It is never published on its own, never in a key table, never
//  in an event. A custodian learns nothing from it. Nothing new leaves the
//  phone in the clear.
//
//  Check marks are the recipient's, kept on the recipient's phone only
//  (`FirstStepsDone`), keyed by the step's id. They are not part of the
//  record and never go anywhere.

/// One step. A short title, an optional note, and optionally the index of
/// one of the envelope's secrets it needs ("Call the bank" points at the
/// account number).
struct FirstStep: Codable, Identifiable, Hashable {
    let id: String
    var title: String
    var note: String
    /// Index into `Envelope.secrets`, or nil. Kept in step with the secrets
    /// list by `Envelope.removeSecret(at:)`; never edit the list around it.
    var secretIndex: Int?

    static let maxTitleCharacters = 80
    static let maxNoteCharacters = 500

    init(id: String = UUID().uuidString, title: String, note: String = "", secretIndex: Int? = nil) {
        self.id = id
        self.title = title
        self.note = note
        self.secretIndex = secretIndex
    }

    var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedNote: String { note.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isBlank: Bool { trimmedTitle.isEmpty }

    /// The steps the owner can pick from instead of starting from nothing.
    /// Titles are the plain thing; the note is the owner's to fill in and
    /// the placeholder says what usually goes there.
    struct Starter: Identifiable, Hashable {
        let title: String
        let hint: String
        var id: String { title }
    }

    static let starters: [Starter] = [
        Starter(title: "Who to call first", hint: "The one or two people who should hear it from a person, and their numbers."),
        Starter(title: "Call the bank", hint: "Which bank, who to ask for, and what to say."),
        Starter(title: "Where the will is", hint: "The drawer, the folder, the lawyer's name."),
        Starter(title: "Where the car title is", hint: "And the spare key."),
        Starter(title: "Subscriptions to cancel", hint: "Phone, streaming, the gym, anything charged every month."),
        Starter(title: "Who takes the pet", hint: "Who has agreed, and the vet's name."),
        Starter(title: "My funeral wishes", hint: "Buried or cremated, where, who speaks, what music."),
        Starter(title: "Bills that must keep being paid", hint: "The mortgage or rent, the power, the insurance."),
    ]
}

extension Envelope {

    /// The steps that have a title, in the owner's order. Blank rows the
    /// owner left behind are not sealed.
    var usableFirstSteps: [FirstStep] { firstSteps.filter { !$0.isBlank } }

    /// Remove one secret and keep every step's link honest: a step that
    /// pointed at it loses the link, a step that pointed past it moves
    /// down by one. Every place that removes a secret must go through here.
    mutating func removeSecret(at index: Int) {
        guard secrets.indices.contains(index) else { return }
        secrets.remove(at: index)
        for i in firstSteps.indices {
            guard let s = firstSteps[i].secretIndex else { continue }
            if s == index { firstSteps[i].secretIndex = nil }
            else if s > index { firstSteps[i].secretIndex = s - 1 }
        }
    }
}

// MARK: - The recipient's check marks

/// Which steps this person has ticked off. Keychain JSON namespaced by the
/// viewer's identity hash like every other store, and wiped by
/// `ContentView.wipeLocalAndEngines`. It is a set of step ids and nothing
/// else: no titles, no envelope, no owner.
enum FirstStepsDone {

    private static func key(_ viewerHash: String) -> String { "seal.firststeps.done.\(viewerHash)" }

    static func load(viewerHash: String) -> Set<String> {
        guard let data = KeychainStore.load(key(viewerHash)),
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(ids)
    }

    static func save(_ done: Set<String>, viewerHash: String) {
        if let data = try? JSONEncoder().encode(done.sorted()) {
            KeychainStore.save(data, for: key(viewerHash))
        }
    }

    static func wipe(ownerHash: String) { KeychainStore.delete(key(ownerHash)) }
}
