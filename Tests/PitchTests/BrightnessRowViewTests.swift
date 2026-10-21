import AppKit
import Testing

@testable import DisplayCore
@testable import Pitch

@MainActor
@Test func theUnfilledPartOfTheTrackIsDrawnNotLeftToTheBlurMaterial() throws {
    // The stock track is a faint translucent grey that disappears over the
    // panel's `.menu` material, leaving only the accent fill visible. Rendered
    // with no background at all, every pixel of the track is the track's own.
    let model = BrightnessRowModel(
        route: BrightnessRoute(method: .ddc, readable: true),
        level: BrightnessLevel(0.2), remembered: nil, failure: nil)
    let view = BrightnessRowView(model: model, onChange: { _, _ in })
    view.frame = NSRect(x: 0, y: 0, width: 300, height: 30)
    view.layoutSubtreeIfNeeded()

    let slider = try #require(view.subviews.compactMap { $0 as? NSSlider }.first)
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)

    // The bitmap is in pixels, the view in points.
    let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
    func pixel(atPoint x: CGFloat) throws -> NSColor {
        try #require(bitmap.colorAt(x: Int(x * scale), y: Int(view.bounds.midY * scale)))
    }

    // Right of the knob at 20%, and clear of the bar's inset end cap.
    #expect(try pixel(atPoint: slider.frame.maxX - 40).alphaComponent > 0.15)
    // Left of the knob: the fill, which is the checkmark's colour.
    #expect(try pixel(atPoint: slider.frame.minX + 8).alphaComponent > 0.6)
}
