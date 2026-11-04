import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let output = root.appendingPathComponent("docs/appstore", isDirectory: true)

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
    artwork: String,
    contentX: CGFloat,
    contentY: CGFloat,
    contentWidth: CGFloat,
    headlineSize: CGFloat
) throws {
    let artworkURL = output.appendingPathComponent(artwork)
    guard let base = NSImage(contentsOf: artworkURL) else {
        fatalError("Could not read \(artworkURL.path)")
    }
    let canvas = NSImage(size: size)
    canvas.lockFocusFlipped(true)
    let bounds = NSRect(origin: .zero, size: size)
    base.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])

    let gold = NSColor(calibratedRed: 0.90, green: 0.68, blue: 0.28, alpha: 1)
    let ivory = NSColor(calibratedRed: 0.98, green: 0.96, blue: 0.91, alpha: 1)

    drawText("SEAL", in: NSRect(x: contentX, y: contentY, width: contentWidth, height: 90), font: .boldSystemFont(ofSize: 52), color: gold, letterSpacing: 10)
    drawText("Pass down\nsecret letters", in: NSRect(x: contentX, y: contentY + 126, width: contentWidth, height: headlineSize * 2.8), font: NSFont(name: "Georgia-Bold", size: headlineSize) ?? .boldSystemFont(ofSize: headlineSize), color: ivory, lineSpacing: 4)

    let rule = NSBezierPath(roundedRect: NSRect(x: contentX, y: contentY + 126 + headlineSize * 2.45 + 52, width: 200, height: 12), xRadius: 6, yRadius: 6)
    gold.setFill()
    rule.fill()
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
    artwork: "Seal-header-art-v2.png",
    contentX: 840,
    contentY: 505,
    contentWidth: 1740,
    headlineSize: 188
)

// Search Results can also carry controls and tight crops on its left edge.
// The first 680 pixels contain no text, logo or essential artwork.
try render(
    size: NSSize(width: 3840, height: 2560),
    filename: "Seal-search-results-3840x2560.png",
    artwork: "Seal-search-art-v2.png",
    contentX: 760,
    contentY: 1450,
    contentWidth: 2280,
    headlineSize: 220
)
