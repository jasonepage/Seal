// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

//  AttachedFileTests.swift
//  Seal
//
//  A file rides inside the sealed payload like a photo (PRODUCT.md section
//  12). What matters: it round trips with its name, a payload sealed before
//  files existed still opens, the media list the engine encrypts includes
//  it, the reader's text cutting keeps page lines honest, and a proposed
//  step becomes a FirstStep within the limits. The on-device model itself
//  is not called here: there may be no model on the phone running this.

enum AttachedFileTests {

    static var suites: [SelfTest.Suite] { [
        .init(name: "files.payloadRoundTrip") { try payloadRoundTrip($0) },
        .init(name: "files.oldPayloadOpens") { try oldPayloadOpens($0) },
        .init(name: "files.inAllMedia") { try inAllMedia($0) },
        .init(name: "files.extension") { try fileExtension($0) },
        .init(name: "files.pieces") { try pieces($0) },
        .init(name: "files.textFromPlain") { try textFromPlain($0) },
        .init(name: "files.proposedStep") { try proposedStep($0) },
    ] }

    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func item(_ name: String?) -> MediaItem {
        var m = MediaItem(blobID: UUID().uuidString, kind: .file, sha256: Data(repeating: 1, count: 32),
                          byteCount: 1234, localName: "x")
        m.fileName = name
        return m
    }

    static func payloadRoundTrip(_ t: SelfTest.Context) throws {
        var envelope = Envelope.new(recipientHash: "R", title: "For Mike", now: t0, revealOrder: 0)
        envelope.files = [item("policy.pdf"), item("deed.PDF")]
        let payload = envelope.payload
        t.equal(payload.files.count, 2, "files are sealed in the payload")
        let data = try EstateEvent.encodeBody(payload)
        let back = try JSONDecoder().decode(Envelope.Payload.self, from: data)
        t.equal(back, payload, "payload round trips through JSON")
        t.equal(back.files[0].fileName, "policy.pdf", "the name survives")
        t.equal(back.files[0].kind, .file, "the kind survives")

        let saved = try JSONEncoder().encode(envelope)
        let loaded = try JSONDecoder().decode(Envelope.self, from: saved)
        t.equal(loaded, envelope, "envelope round trips through the keychain shape")
    }

    /// A payload sealed before files existed has no "files" key, and a
    /// photo item from before has no "fileName".
    static func oldPayloadOpens(_ t: SelfTest.Context) throws {
        let old = """
        {"letter":"Hello.","photos":[{"blobID":"b","kind":"photo","sha256":"AAAA","byteCount":4,"localName":"b"}],"revealOrder":0,"secrets":[],"title":"For Karen","writtenAtEpoch":1800000000}
        """
        let payload = try JSONDecoder().decode(Envelope.Payload.self, from: Data(old.utf8))
        t.check(payload.files.isEmpty, "a payload without the key decodes as no files")
        t.equal(payload.photos.count, 1, "the old photo is intact")
        t.check(payload.photos[0].fileName == nil, "an old photo has no file name")
    }

    static func inAllMedia(_ t: SelfTest.Context) throws {
        var envelope = Envelope.new(recipientHash: "R", title: "For Mike", now: t0, revealOrder: 0)
        let f = item("a.txt")
        envelope.files = [f]
        t.check(envelope.allMedia.contains { $0.blobID == f.blobID }, "the engine's media list includes files")
        t.check(envelope.blobIDs.contains(f.blobID), "the vault commitment covers the file blob")
        t.check(envelope.contentsSummary.contains("a file"), "the inbox line counts it")
    }

    static func fileExtension(_ t: SelfTest.Context) throws {
        t.equal(item("policy.pdf").fileExtension, "pdf", "lowercase extension")
        t.equal(item("DEED.PDF").fileExtension, "pdf", "uppercase is lowered")
        t.equal(item("notes").fileExtension, "", "no dot means no extension")
        t.equal(item(nil).fileExtension, "", "no name means no extension")
        t.check(FileReader.isReadable(item("a.pdf")), "a PDF can be read")
        t.check(FileReader.isReadable(item("a.txt")), "a text file can be read")
        t.check(!FileReader.isReadable(item("a.zip")), "a zip cannot be read for steps")
        t.check(!FileReader.isReadable(item("a.jpg")), "a picture cannot be read for steps")
    }

    static func pieces(_ t: SelfTest.Context) throws {
        let one = FileReader.pieces(of: "[page 1]\nshort", maxCharacters: 100)
        t.equal(one.count, 1, "short text is one piece")
        let lines = (1...40).map { "[page \($0)]\n" + String(repeating: "w", count: 60) }.joined(separator: "\n")
        let many = FileReader.pieces(of: lines, maxCharacters: 300, maxPieces: 4)
        t.equal(many.count, 4, "the piece cap holds")
        for piece in many {
            t.check(piece.count <= 300 + 62, "a piece is about the size asked for", "\(piece.count)")
            t.check(piece.contains("[page "), "every piece carries a page line")
        }
        t.check(FileReader.pieces(of: "").isEmpty, "empty text is no pieces")
    }

    static func textFromPlain(_ t: SelfTest.Context) throws {
        let text = FileReader.text(from: Data("Call the bank.\nPolicy 4471.".utf8), fileExtension: "txt")
        t.check(text?.hasPrefix("[page 1]") == true, "plain text gets one page line")
        t.check(text?.contains("Policy 4471") == true, "the words are there")
        t.check(FileReader.text(from: Data("   ".utf8), fileExtension: "txt") == nil, "blank text is nothing")
        t.check(FileReader.text(from: Data([0, 1, 2]), fileExtension: "zip") == nil, "a zip is not read")
        t.check(FileReader.text(from: Data([0, 1, 2]), fileExtension: "pdf") == nil, "junk is not a PDF")
    }

    static func proposedStep(_ t: SelfTest.Context) throws {
        let long = String(repeating: "x", count: 200)
        let step = FileReader.ProposedStep(title: long, note: "Policy 4471", page: 2)
        let first = step.asFirstStep
        t.equal(first.title.count, FirstStep.maxTitleCharacters, "the title is cut to the limit")
        t.equal(first.note, "Policy 4471 (page 2)", "the page joins the note")
        let bare = FileReader.ProposedStep(title: "Call the bank", note: "", page: 0).asFirstStep
        t.equal(bare.note, "", "no note and no page stays empty")
        t.check(!bare.isBlank, "a titled step is not blank")
    }
}
