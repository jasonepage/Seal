import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let site = root.appendingPathComponent("site", isDirectory: true)

struct Card {
    let filename: String
    let colors: [NSColor]
    let kicker: String
    let headline: String
    let detail: String
    let button: String
    let buttonColor: NSColor
    let buttonTextColor: NSColor
    let art: String
    let artRect: NSRect
}

func draw(_ text: String, in rect: NSRect, font: NSFont, color: NSColor, spacing: CGFloat = 0) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byWordWrapping
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
        .kern: spacing,
        .paragraphStyle: paragraph
    ]
    text.draw(in: rect, withAttributes: attributes)
}

let cards = [
    Card(
        filename: "social-home.png",
        colors: [NSColor(calibratedRed: 0.03, green: 0.035, blue: 0.045, alpha: 1), NSColor(calibratedRed: 0.16, green: 0.13, blue: 0.10, alpha: 1)],
        kicker: "LETTERS KEPT UNTIL IT IS TIME",
        headline: "Someone may\nhave left a letter.",
        detail: "Open it with the security key\nthey gave you.",
        button: "Open your envelopes",
        buttonColor: NSColor(calibratedRed: 0.84, green: 0.64, blue: 0.23, alpha: 1),
        buttonTextColor: NSColor(calibratedWhite: 0.08, alpha: 1),
        art: "inside-seal-app.png",
        artRect: NSRect(x: 720, y: 70, width: 440, height: 440)
    ),
    Card(
        filename: "social-give.png",
        colors: [NSColor(calibratedRed: 0.15, green: 0.025, blue: 0.02, alpha: 1), NSColor(calibratedRed: 0.40, green: 0.13, blue: 0.09, alpha: 1)],
        kicker: "A GIFT FOR A HARD CONVERSATION",
        headline: "Help them\nleave the letter.",
        detail: "Security keys, the Seal app,\nand one clear printed card.",
        button: "Give Seal",
        buttonColor: NSColor(calibratedRed: 0.94, green: 0.71, blue: 0.63, alpha: 1),
        buttonTextColor: NSColor(calibratedRed: 0.18, green: 0.05, blue: 0.035, alpha: 1),
        art: "harbor-home.png",
        artRect: NSRect(x: 675, y: 55, width: 510, height: 510)
    ),
    Card(
        filename: "social-get.png",
        colors: [NSColor(calibratedRed: 0.035, green: 0.03, blue: 0.025, alpha: 1), NSColor(calibratedRed: 0.17, green: 0.14, blue: 0.10, alpha: 1)],
        kicker: "THE COMPLETE SEAL SETUP",
        headline: "Seal it in\none evening.",
        detail: "Security keys, the Seal app,\nand one clear printed card.",
        button: "Get a Seal kit",
        buttonColor: NSColor(calibratedRed: 0.84, green: 0.64, blue: 0.23, alpha: 1),
        buttonTextColor: NSColor(calibratedWhite: 0.08, alpha: 1),
        art: "key-kit-icon.png",
        artRect: NSRect(x: 720, y: 75, width: 440, height: 440)
    )
]

for card in cards {
    let canvas = NSImage(size: NSSize(width: 1200, height: 630))
    canvas.lockFocusFlipped(true)
    let bounds = NSRect(x: 0, y: 0, width: 1200, height: 630)
    NSGradient(colors: card.colors)?.draw(in: bounds, angle: 0)

    draw("Seal.", in: NSRect(x: 70, y: 53, width: 200, height: 42), font: .boldSystemFont(ofSize: 30), color: NSColor(calibratedWhite: 0.96, alpha: 1))
    draw(card.kicker, in: NSRect(x: 70, y: 132, width: 570, height: 30), font: .boldSystemFont(ofSize: 17), color: card.buttonColor, spacing: 2.5)
    draw(card.headline, in: NSRect(x: 65, y: 176, width: 620, height: 174), font: NSFont(name: "Georgia-Bold", size: 70) ?? .boldSystemFont(ofSize: 70), color: NSColor(calibratedWhite: 0.98, alpha: 1))
    draw(card.detail, in: NSRect(x: 70, y: 377, width: 570, height: 76), font: .systemFont(ofSize: 24, weight: .medium), color: NSColor(calibratedWhite: 0.86, alpha: 1))

    let button = NSBezierPath(roundedRect: NSRect(x: 70, y: 500, width: 322, height: 64), xRadius: 32, yRadius: 32)
    card.buttonColor.setFill()
    button.fill()
    let buttonStyle = NSMutableParagraphStyle()
    buttonStyle.alignment = .center
    card.button.draw(in: NSRect(x: 70, y: 518, width: 322, height: 32), withAttributes: [
        .font: NSFont.boldSystemFont(ofSize: 22),
        .foregroundColor: card.buttonTextColor,
        .paragraphStyle: buttonStyle
    ])

    let artURL = site.appendingPathComponent(card.art)
    guard let art = NSImage(contentsOf: artURL) else {
        fatalError("Could not read \(artURL.path)")
    }
    art.draw(in: card.artRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    canvas.unlockFocus()

    guard let tiff = canvas.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let data = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode \(card.filename)")
    }
    let destination = site.appendingPathComponent(card.filename)
    try data.write(to: destination)
    print("Rendered \(destination.path)")
}
