// Writes the app icon as an Icon Composer bundle (Resources/AppIcon.icon),
// which `scripts/make-icon.sh` compiles with `actool` into the Assets.car and
// AppIcon.icns that `scripts/package-app.sh` copies into the app.
//
// An Icon Composer icon, not a flat .icns with its own rounded tile: macOS 26
// and later treat a flat icon as legacy and shrink it onto a grey tile. From
// the bundle the system draws the shape, the glass lighting, and the dark and
// tinted variants itself; actool still writes a .icns for older systems.
//
// A standalone script, not a target: it is build tooling, and adding it to
// Package.swift would put AppKit drawing code in the dependency graph of a
// package whose library target is forbidden from importing AppKit at all.
//
// The glyph is the `display` SF Symbol — the same one the status item draws in
// the menu bar (StatusMenuController.swift) and the same one the display picker
// numbers. Taking it from the system rather than transcribing a path is what
// keeps the icon and the menu bar from drifting apart: there is one symbol, and
// if Apple redraws it both follow.
//
// The fill matches InOut's icon so the two sit together as a pair.
//
// Usage: swift Tools/GenerateIcon.swift <AppIcon.icon>

import AppKit
import Foundation

private enum Icon {
    /// Icon Composer's canvas. The fill covers all of it; the system applies
    /// the rounded mask, so nothing here draws a tile or corners.
    static let canvas = 1024
    /// Glyph size as a fraction of the canvas. `display` is a wide, squat
    /// symbol: fitted by its longest side it reads smaller than a square glyph
    /// of the same nominal box, so the box is generous.
    static let glyphFraction: CGFloat = 0.66

    static let fillTop = "srgb:0.24300,0.27100,0.32500,1.00000"
    static let fillBottom = "srgb:0.08600,0.10200,0.12900,1.00000"
    static let stroke = NSColor(srgbRed: 0.965, green: 0.973, blue: 0.984, alpha: 1)
}

/// The glyph alone, on a transparent canvas, as the bundle's one layer.
private func renderGlyph() -> NSBitmapImageRep? {
    let side = CGFloat(Icon.canvas)
    guard
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Icon.canvas, pixelsHigh: Icon.canvas,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: rep)
    else { return nil }

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    context.shouldAntialias = true

    let box = side * Icon.glyphFraction
    guard
        let symbol = NSImage(systemSymbolName: "display", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: box, weight: .regular))
    else { return nil }
    symbol.isTemplate = true

    // Fitted by whichever side runs out first, so the monitor keeps its shape
    // instead of being stretched to fill a square it was never drawn for.
    let fit = min(box / symbol.size.width, box / symbol.size.height)
    let drawn = NSSize(width: symbol.size.width * fit, height: symbol.size.height * fit)
    let frame = NSRect(
        x: (side - drawn.width) / 2,
        y: (side - drawn.height) / 2,
        width: drawn.width,
        height: drawn.height)

    // `.sourceAtop` recolours only what is already there: the symbol's own
    // alpha. The canvas is otherwise empty, so no transparency layer is needed.
    symbol.draw(in: frame)
    Icon.stroke.setFill()
    frame.fill(using: .sourceAtop)
    return rep
}

private let manifest = """
{
  "fill" : {
    "linear-gradient" : [
      "\(Icon.fillTop)",
      "\(Icon.fillBottom)"
    ]
  },
  "groups" : [
    {
      "layers" : [ { "image-name" : "glyph.png", "name" : "glyph" } ],
      "shadow" : { "kind" : "neutral", "opacity" : 0.5 },
      "translucency" : { "enabled" : true, "value" : 0.3 }
    }
  ],
  "supported-platforms" : { "squares" : [ "macOS" ] }
}

"""

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: GenerateIcon <AppIcon.icon>\n".utf8))
    exit(2)
}

let bundle = URL(fileURLWithPath: arguments[1])
let assets = bundle.appendingPathComponent("Assets")
try? FileManager.default.removeItem(at: bundle)
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

guard let rep = renderGlyph(), let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("failed to render the glyph\n".utf8))
    exit(1)
}
try png.write(to: assets.appendingPathComponent("glyph.png"))
try Data(manifest.utf8).write(to: bundle.appendingPathComponent("icon.json"))

print("Wrote \(bundle.path)")
