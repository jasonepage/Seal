import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let output = root.appendingPathComponent("docs/appstore", isDirectory: true)
let iconURL = root.appendingPathComponent("site/harbor-home.png")

guard let harbor = NSImage(contentsOf: iconURL) else {
    fatalError("Could not read \(iconURL.path)")
}

func drawText(
    _ text: String,
    in rect: NSRect,
    font: NSFont,
    color: NSColor,
    lineSpacing: CGFloat = 0,
    letterSpacing: CGFloat = 0
) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byWordWrapping
    paragraph.lineSpacing = lineSpacing
    text.draw(in: rect, withAttributes: [
        .font: font,
        .foregroundColor: color,
        .kern: letterSpacing,
        .paragraphStyle: paragraph
    ])
}

func render(
    size: NSSize,
    filename: String,
    kicker: String,
    headline: String,
    detail: String,
    contentX: CGFloat,
    contentY: CGFloat,
    contentWidth: CGFloat,
    headlineSize: CGFloat,
    harborRect: NSRect
) throws {
    let canvas = NSImage(size: size)
    canvas.lockFocusFlipped(true)
    let bounds = NSRect(origin: .zero, size: size)
    NSGradient(colors: [
        NSColor(calibratedRed: 0.025, green: 0.028, blue: 0.035, alpha: 1),
        NSColor(calibratedRed: 0.17, green: 0.13, blue: 0.08, alpha: 1)
    ])?.draw(in: bounds, angle: 0)

    let gold = NSColor(calibratedRed: 0.90, green: 0.68, blue: 0.28, alpha: 1)
    let ivory = NSColor(calibratedRed: 0.98, green: 0.96, blue: 0.91, alpha: 1)
    let muted = NSColor(calibratedRed: 0.73, green: 0.70, blue: 0.64, alpha: 1)

    drawText("SEAL", in: NSRect(x: contentX, y: contentY, width: contentWidth, height: 90), font: .boldSystemFont(ofSize: 54), color: ivory, letterSpacing: 9)
    drawText(kicker, in: NSRect(x: contentX, y: contentY + 130, width: contentWidth, height: 100), font: .boldSystemFont(ofSize: 54), color: gold, letterSpacing: 5)
    drawText(headline, in: NSRect(x: contentX, y: contentY + 245, width: contentWidth, height: headlineSize * 2.7), font: NSFont(name: "Georgia-Bold", size: headlineSize) ?? .boldSystemFont(ofSize: headlineSize), color: ivory, lineSpacing: 5)
    drawText(detail, in: NSRect(x: contentX, y: contentY + 245 + headlineSize * 2.45, width: contentWidth, height: 220), font: .systemFont(ofSize: 55, weight: .medium), color: muted, lineSpacing: 12)

    let rule = NSBezierPath(roundedRect: NSRect(x: contentX, y: contentY + 245 + headlineSize * 2.45 + 230, width: 210, height: 13), xRadius: 7, yRadius: 7)
    gold.setFill()
    rule.fill()

    harbor.draw(in: harborRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    canvas.unlockFocus()

    guard let tiff = canvas.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let data = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode \(filename)")
    }
    let destination = output.appendingPathComponent(filename)
    try data.write(to: destination)
    print("Rendered \(destination.path)")
}

// Apple places a close control over the left edge of Header assets.
// The first 760 pixels are intentionally decorative background only.
try render(
    size: NSSize(width: 3840, height: 1646),
    filename: "Seal-header-3840x1646.png",
    kicker: "LETTERS KEPT UNTIL IT IS TIME",
    headline: "Leave what matters.\nSeal the rest.",
    detail: "Letters, photos and passwords for the people you love.",
    contentX: 840,
    contentY: 250,
    contentWidth: 1880,
    headlineSize: 180,
    harborRect: NSRect(x: 2750, y: 245, width: 1040, height: 1040)
)

// Search Results can also carry controls and tight crops on its left edge.
// The first 680 pixels contain no text, logo or essential artwork.
try render(
    size: NSSize(width: 3840, height: 2560),
    filename: "Seal-search-results-3840x2560.png",
    kicker: "PRIVATE UNTIL IT IS TIME",
    headline: "A letter that\nknows when to wait.",
    detail: "End-to-end encrypted. Opened only with the people and keys you chose.",
    contentX: 760,
    contentY: 1080,
    contentWidth: 2760,
    headlineSize: 210,
    harborRect: NSRect(x: 2320, y: 100, width: 1260, height: 1260)
)
