import AppKit

// Generates SousVide.app's icon: the heart.badge.bolt glyph in black on a white
// rounded-rect (macOS squircle-ish), emitted as a full .icns via iconutil.
// Run: swift tools/make-sousvide-icon.swift

func renderIcon(_ px: CGFloat) -> Data {
    let image = NSImage(size: NSSize(width: px, height: px))
    image.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext

    // Transparent margin around the rounded plate (matches macOS icon padding).
    let margin = px * 0.10
    let plate = CGRect(x: margin, y: margin, width: px - margin * 2, height: px - margin * 2)
    let radius = plate.width * 0.2237            // Apple's continuous-corner ratio
    let path = NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius)
    NSColor.white.setFill()
    path.fill()

    // Black symbol centered at ~52% of the plate.
    let symPt = plate.width * 0.52
    let cfg = NSImage.SymbolConfiguration(pointSize: symPt, weight: .medium)
        .applying(NSImage.SymbolConfiguration(hierarchicalColor: .black))
    if let sym = NSImage(systemSymbolName: "heart.badge.bolt", accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) {
        let s = sym.size
        let r = NSRect(x: plate.midX - s.width / 2, y: plate.midY - s.height / 2, width: s.width, height: s.height)
        sym.draw(in: r)
    }
    _ = ctx
    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { fatalError("encode failed") }
    return png
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("SousVide.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)

let specs: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in specs {
    try! renderIcon(px).write(to: iconset.appendingPathComponent("\(name).png"))
}

let out = URL(fileURLWithPath: "SousVide.app/Contents/Resources/SousVide.icns")
try? fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "✓ wrote \(out.path)" : "✗ iconutil failed (\(p.terminationStatus))")
