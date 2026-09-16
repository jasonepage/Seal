// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import PDFKit
#if canImport(FoundationModels)
import FoundationModels
#endif

//  FileReading.swift
//  Seal
//
//  "READ IT FOR ME" (PRODUCT.md section 12).
//
//  An attached file is bytes to the envelope. This file is the one place
//  those bytes are ever looked at, and everything here runs on the phone:
//
//    FileReader.text        pulls the words out of a PDF (PDFKit, page by
//                           page) or a plain text file. Nothing else is
//                           read; a zip, an image or a Word file returns
//                           nil and the card says so.
//    FileReader.steps       hands the words, in pieces, to Apple's on-device
//                           model and asks for "what to do first" steps that
//                           point at the page they came from. With no model
//                           on this phone there are no steps, and the file
//                           is still attached and sealed like any other.
//
//  The promise, decided in PRODUCT.md before this was written: nothing in
//  a file leaves the phone. Not to a server, not to us, not to Apple's
//  private cloud. The on-device model is the only reader, and only when
//  the phone has it. No index is kept in this first cut: the reading is
//  done on demand, and its output is the steps the owner ticks, which are
//  sealed with the envelope like every other step.

enum FileReader {

    /// Files the reader can pull words from. Everything else attaches and
    /// seals fine; it just cannot be read for steps.
    static let readableExtensions: Set<String> = ["pdf", "txt", "text", "md", "csv", "json"]

    static func isReadable(_ item: MediaItem) -> Bool {
        readableExtensions.contains(item.fileExtension)
    }

    /// The words, with a "[page N]" line before each page so a step can
    /// say where it came from. Nil when there is nothing to read.
    static func text(from data: Data, fileExtension: String) -> String? {
        switch fileExtension {
        case "pdf":
            guard let document = PDFDocument(data: data) else { return nil }
            var out = ""
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index), let words = page.string else { continue }
                let trimmed = words.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                out += "[page \(index + 1)]\n\(trimmed)\n\n"
            }
            return out.isEmpty ? nil : out
        case "txt", "text", "md", "csv", "json":
            guard let words = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
            let trimmed = words.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : "[page 1]\n" + trimmed
        default:
            return nil
        }
    }

    /// Cut the words into pieces the on-device model can hold. Pieces
    /// break at a page line when there is one nearby, so a step's page
    /// number stays honest. Pure, so the test can check it.
    static func pieces(of text: String, maxCharacters: Int = 3000, maxPieces: Int = 6) -> [String] {
        var out: [String] = []
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = String(line)
            if current.count + l.count + 1 > maxCharacters, !current.isEmpty {
                out.append(current)
                current = ""
                if out.count == maxPieces { return out }
            }
            current += (current.isEmpty ? "" : "\n") + l
        }
        if !current.isEmpty, out.count < maxPieces { out.append(current) }
        return out
    }

    /// True only when the on-device model is on this phone and ready. The
    /// same test the interview uses.
    static var canRead: Bool { InterviewHelper.isAvailable }

    /// One step the reader proposes. The page is for the owner's eyes: it
    /// goes into the note as "(page 2)" if they keep the step.
    struct ProposedStep: Identifiable, Hashable {
        let id = UUID().uuidString
        var title: String
        var note: String
        var page: Int

        var asFirstStep: FirstStep {
            var n = note.trimmingCharacters(in: .whitespacesAndNewlines)
            if page > 0 { n += (n.isEmpty ? "" : " ") + "(page \(page))" }
            return FirstStep(title: String(title.prefix(FirstStep.maxTitleCharacters)),
                             note: String(n.prefix(FirstStep.maxNoteCharacters)))
        }
    }

    static let maximumSteps = 8

    /// The steps, or an empty list when there is no model, nothing to
    /// read, or the model gave nothing usable. Never throws to the owner:
    /// a reader that did not help is not an error.
    static func steps(from text: String, fileName: String, recipientName: String) async -> [ProposedStep] {
        guard canRead else { return [] }
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            var out: [ProposedStep] = []
            for piece in pieces(of: text) {
                let prompt = """
                The file is called \(fileName). The steps are for \(recipientName), who \
                is reading this after the writer has died and needs to know what to do.

                Here is part of the file:

                \(piece)

                List the few things \(recipientName) should do first because of what is \
                in this part, each with the exact detail it needs copied from the text \
                (a phone number, a policy or account number, a name, an address, a date) \
                and the page it is on.
                """
                do {
                    let result = try await OnDeviceDrafter.respond(instructions: instructions, prompt: prompt, as: ReadSteps.self)
                    for step in result.steps {
                        let title = OnDeviceDrafter.houseStyle(step.title)
                        guard !title.isEmpty else { continue }
                        out.append(ProposedStep(title: title, note: OnDeviceDrafter.houseStyle(step.note), page: max(0, step.page)))
                        if out.count >= maximumSteps { return out }
                    }
                } catch {
                    continue
                }
            }
            return out
        }
        #endif
        return []
    }

    static let instructions = """
    You read part of a document that a person attached to a sealed envelope \
    for someone they love, to be opened after they have died. You turn what \
    is in it into a short list of things to do first.

    Rules you follow exactly:
    Every step is one plain instruction the reader can act on, twelve words at most.
    Copy every number, name, address and date word for word from the text. \
    Invent nothing. If the text has no detail for a step, leave the note empty.
    Only steps that come from this text. No general advice.
    Give the page number from the nearest "[page N]" line above the detail, or 0.
    At most five steps, most urgent first. Fewer is fine. None is fine.
    Never use an em dash.
    """
}

#if canImport(FoundationModels)

@available(iOS 26, *)
@Generable
struct ReadStep {
    @Guide(description: "One plain instruction the reader can act on, twelve words at most.")
    var title: String

    @Guide(description: "The exact detail the instruction needs, copied word for word from the text: a phone number, a policy or account number, a name, an address, a date. Empty if there is none.")
    var note: String

    @Guide(description: "The page number the detail came from, taken from the nearest [page N] line, or 0 if unknown.")
    var page: Int
}

@available(iOS 26, *)
@Generable
struct ReadSteps {
    @Guide(description: "Up to five steps, most urgent first. Fewer is fine.")
    var steps: [ReadStep]
}

#endif
