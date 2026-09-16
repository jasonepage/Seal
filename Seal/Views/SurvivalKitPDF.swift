// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

//  SurvivalKitPDF.swift
//  Seal
//
//  THE PRINTED SURVIVAL KIT. One page per key holder, made on the phone,
//  meant to live in the drawer with the key.
//
//  A key holder will not think about this app for years. This page is
//  what they can hold: whose key this is, what Seal is, what to do when
//  the time comes, and the two things to remember. It carries a QR code
//  to the how-it-works page. The capsule and the verifier are documented
//  in docs/CAPSULE.md and on the site, not here: this page is meant to
//  reassure, not to warn.
//
//  WHAT IS NOT ON IT, BY CONSTRUCTION. `SurvivalKit.Content` is built from
//  two names, the rule and a date. It cannot be built from an envelope, a
//  secret, a share or a key table, because the function does not take
//  them. There is nothing to leak because nothing was given. A test checks
//  the words too.

enum SurvivalKit {

    static let howItWorksURL = "https://sealmessenger.com/how-it-works.html"
    static let verifierURL = "https://github.com/jasonepage/Seal"

    /// Everything the page says, as plain strings, so it can be read and
    /// tested without drawing anything.
    struct Section: Hashable {
        let heading: String
        let body: String
    }

    struct Content: Hashable {
        let title: String
        let belongsTo: String
        let sections: [Section]
        let footer: String

        var allText: String {
            ([title, belongsTo] + sections.flatMap { [$0.heading, $0.body] } + [footer]).joined(separator: "\n")
        }
    }

    /// The words. Written to be read by somebody over sixty, years from
    /// now, who has not thought about this app since the evening they got
    /// the key. The plain thing first, every time.
    static func content(ownerName: String, custodianName: String, policy: ReleasePolicy,
                        custodianCount: Int, printedOn: Date) -> Content {
        let owner = ownerName.isEmpty ? "the owner" : ownerName
        let holder = custodianName.isEmpty ? "you" : custodianName
        let others = max(0, custodianCount - 1)
        let howMany: String
        if policy.threshold == 1 {
            howMany = custodianCount == 1
                ? "You are the only key holder, and your key alone is enough."
                : "Any one key holder is enough. There are \(custodianCount) of you."
        } else {
            howMany = "It takes \(policy.threshold) of \(custodianCount) key holders together. Yours is one of them\(others > 0 ? ", and \(others == 1 ? "one other person holds" : "\(others) other people hold") a key too" : "")."
        }
        let sections: [Section] = [
            Section(heading: "What this is", body:
             "\(owner) wrote sealed envelopes for the people they will leave behind: letters, photos, a voice, and the passwords and papers a family needs. The envelopes are locked on \(owner)'s phone and stored in encrypted form. Nobody can open them early, not Apple, not the people who made Seal, and not you. This key is one of the keys that can open them after \(owner) is gone. Keep it somewhere you will still find it in ten years. It is useless to a thief and precious to the family."),
            Section(heading: "What to do when the time comes", body:
             "Open Seal on your phone. It will tell you what it knows and what you can do. If \(owner) has not opened Seal for \(policy.silenceDays) days, you may start a claim. \(owner) is then warned every day for \(policy.warningDays) days, and can stop everything by opening the app once. After that comes a quiet period of \(policy.graceDays) days. Then key holders tap their keys on their own phones. \(howMany) Whoever started the claim combines the keys, and the envelopes open on the phones of the people they were written for. You will not see what is in them. That is by design."),
            Section(heading: "Two things to remember", body:
             "First: this key can only open things after a long silence, days of warnings, and enough other key holders tapping too. It cannot be used to read anything on its own. Second: about once a year Seal will ask you to tap the key on your phone to show you still have it. Please do. It tells \(owner) the key is in good hands."),
        ]
        let date = printedOn.formatted(date: .long, time: .omitted)
        return Content(
            title: "A key for \(owner)'s sealed envelopes",
            belongsTo: "This key was given to \(holder).",
            sections: sections,
            footer: "Printed \(date). This page holds no passwords, no secrets and nothing about the envelopes. It is safe to keep with the key. Scan the code for how Seal works: \(howItWorksURL)")
    }

    // MARK: - Drawing

    /// US Letter. The page is drawn with UIKit text, no PDF library.
    static func render(_ content: Content) -> Data {
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let margin: CGFloat = 54
        let textWidth = page.width - margin * 2
        let renderer = UIGraphicsPDFRenderer(bounds: page, format: {
            let f = UIGraphicsPDFRendererFormat()
            f.documentInfo = [kCGPDFContextTitle as String: content.title,
                              kCGPDFContextCreator as String: "Seal"]
            return f
        }())
        return renderer.pdfData { ctx in
            ctx.beginPage()
            var y = margin

            func draw(_ text: String, font: UIFont, color: UIColor = .black, spacingAfter: CGFloat = 8, width: CGFloat = textWidth) {
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = 2
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
                let bounds = (text as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                                             options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                             attributes: attributes, context: nil)
                (text as NSString).draw(with: CGRect(x: margin, y: y, width: width, height: ceil(bounds.height)),
                                        options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes, context: nil)
                y += ceil(bounds.height) + spacingAfter
            }

            // The seal mark, in ink, top left, and the QR top right.
            let qrSize: CGFloat = 96
            if let qr = qrImage(howItWorksURL, size: qrSize) {
                qr.draw(in: CGRect(x: page.width - margin - qrSize, y: margin - 6, width: qrSize, height: qrSize))
                let caption = "How Seal works"
                let captionAttributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 8), .foregroundColor: UIColor.darkGray]
                (caption as NSString).draw(at: CGPoint(x: page.width - margin - qrSize + 14, y: margin + qrSize - 4), withAttributes: captionAttributes)
            }
            draw("Seal", font: .systemFont(ofSize: 11, weight: .semibold), color: .darkGray, spacingAfter: 2, width: textWidth - qrSize - 12)
            draw(content.title, font: .systemFont(ofSize: 22, weight: .bold), spacingAfter: 6, width: textWidth - qrSize - 12)
            draw(content.belongsTo, font: .systemFont(ofSize: 13, weight: .semibold), spacingAfter: 18, width: textWidth - qrSize - 12)

            for section in content.sections {
                draw(section.heading, font: .systemFont(ofSize: 12.5, weight: .bold), spacingAfter: 3)
                draw(section.body, font: .systemFont(ofSize: 10.5), color: UIColor(white: 0.12, alpha: 1), spacingAfter: 12)
            }

            // The footer sits at the bottom whatever the body did.
            let footerFont = UIFont.systemFont(ofSize: 8.5)
            let footerAttributes: [NSAttributedString.Key: Any] = [.font: footerFont, .foregroundColor: UIColor.darkGray]
            let footerBounds = (content.footer as NSString).boundingRect(with: CGSize(width: textWidth, height: 200),
                                                                          options: [.usesLineFragmentOrigin], attributes: footerAttributes, context: nil)
            let footerY = page.height - margin - ceil(footerBounds.height)
            ctx.cgContext.setStrokeColor(UIColor.lightGray.cgColor)
            ctx.cgContext.setLineWidth(0.5)
            ctx.cgContext.move(to: CGPoint(x: margin, y: footerY - 8))
            ctx.cgContext.addLine(to: CGPoint(x: page.width - margin, y: footerY - 8))
            ctx.cgContext.strokePath()
            (content.footer as NSString).draw(with: CGRect(x: margin, y: footerY, width: textWidth, height: ceil(footerBounds.height)),
                                              options: [.usesLineFragmentOrigin], attributes: footerAttributes, context: nil)
        }
    }

    /// A QR code from Core Image, scaled with no smoothing so the modules
    /// stay square on paper.
    static func qrImage(_ string: String, size: CGFloat) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = size / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// The whole thing: words, page, file in the temporary directory for
    /// the share sheet. The file name carries the key holder's first name
    /// so two printed pages are not confused in a drawer.
    static func makeFile(ownerName: String, custodianName: String, policy: ReleasePolicy,
                         custodianCount: Int, now: Date) throws -> URL {
        let content = content(ownerName: ownerName, custodianName: custodianName, policy: policy,
                              custodianCount: custodianCount, printedOn: now)
        let data = render(content)
        let safeName = custodianName.split(separator: " ").first.map(String.init)?
            .filter { $0.isLetter || $0.isNumber } ?? "keyholder"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Seal-key-\(safeName.isEmpty ? "keyholder" : safeName).pdf")
        try data.write(to: url, options: .atomic)
        return url
    }
}
