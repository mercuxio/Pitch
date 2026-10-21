import CoreGraphics
import Foundation
import DisplayCore

/// What `brightness set` refuses to do, as opposed to what the OS refuses.
enum BrightnessCommandError: Error, Equatable {
    /// Software dimming lives in a colour table the system releases when the
    /// process that set it exits, so from a one-shot command it would flash and
    /// vanish. The menu bar app, which stays running, is where it belongs.
    case softwareDimmingDoesNotOutliveTheCommand(displayIndex: Int)
}

/// One display's brightness situation, ready to render.
struct BrightnessRow: Equatable {
    let index: Int
    let name: String
    let route: BrightnessRoute?
    /// `nil` when the display is write-only, has no route, or its level is not
    /// something a separate process can know (see `runBrightnessList`).
    let level: BrightnessLevel?
}

private func row(
    index: Int, id: CGDirectDisplayID,
    enumerator: DisplayEnumerating, router: BrightnessRouter
) throws -> BrightnessRow {
    let route = router.route(for: id)
    // Gamma has no hardware to ask: its "level" is only ever what the running
    // process last applied, so a fresh process would report 100% whatever is on
    // screen. Better no number than a confident wrong one.
    var level: BrightnessLevel?
    if let route, route.method != .gamma, route.readable {
        level = try router.level(for: id)
    }
    return BrightnessRow(
        index: index, name: try enumerator.device(for: id).localizedName,
        route: route, level: level)
}

/// Probes and reads only. Never writes, so it is safe unattended.
func runBrightnessList(enumerator: DisplayEnumerating, router: BrightnessRouter) throws -> String {
    let rows = try enumerator.onlineDisplayIDs().enumerated().map { offset, id in
        try row(index: offset + 1, id: id, enumerator: enumerator, router: router)
    }
    return Renderer.renderBrightnessList(rows)
}

/// Probes and reads only.
func runBrightnessGet(
    displayIndex: Int?, enumerator: DisplayEnumerating, router: BrightnessRouter
) throws -> String {
    let (index, id) = try resolveDisplayWithIndex(index: displayIndex, enumerator: enumerator)
    return Renderer.renderBrightnessList(
        [try row(index: index, id: id, enumerator: enumerator, router: router)])
}

/// Writes to the screen — and for a DDC display, to the monitor itself, where it
/// persists after this process exits. Never run unattended.
func runBrightnessSet(
    _ options: BrightnessSetOptions, enumerator: DisplayEnumerating, router: BrightnessRouter
) throws -> String {
    let (index, id) = try resolveDisplayWithIndex(
        index: options.displayIndex, enumerator: enumerator)

    guard let route = router.route(for: id) else { throw DisplayError.brightnessUnsupported(id) }
    guard route.method != .gamma else {
        throw BrightnessCommandError.softwareDimmingDoesNotOutliveTheCommand(displayIndex: index)
    }

    let applied = try router.setLevel(BrightnessLevel(options.percent / 100), for: id)
    return Renderer.renderBrightnessSet(
        index: index, name: try enumerator.device(for: id).localizedName,
        method: route.method, requested: options.percent / 100, applied: applied)
}
