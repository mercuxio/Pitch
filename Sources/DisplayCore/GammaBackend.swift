import CoreGraphics
import Foundation

/// A display's gamma table, one array per channel.
public struct GammaTable: Equatable, Sendable {
    public var red: [Float]
    public var green: [Float]
    public var blue: [Float]

    public init(red: [Float], green: [Float], blue: [Float]) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    func scaled(by factor: Double) -> GammaTable {
        let f = Float(factor)
        return GammaTable(red: red.map { $0 * f }, green: green.map { $0 * f }, blue: blue.map { $0 * f })
    }
}

/// The CoreGraphics calls gamma dimming rests on, as a seam: tests drive the
/// backend's logic without touching a real display's colour tables.
public protocol GammaTables: Sendable {
    func canDrive(_ id: CGDirectDisplayID) -> Bool
    func capture(_ id: CGDirectDisplayID) -> GammaTable?
    /// A `CGError` code; 0 is success.
    func apply(_ table: GammaTable, to id: CGDirectDisplayID) -> Int32
    /// Every display back to its ColorSync profile.
    func restoreSystemSettings()
}

/// Software dimming (spec §18.5): the display's own gamma table, scaled.
///
/// Works on any active display, which is why it is the last resort. It does not
/// deepen blacks, and it shares one ramp with Night Shift and True Tone.
public final class GammaBackend: BrightnessBackend, @unchecked Sendable {
    public let method = BrightnessMethod.gamma

    private let tables: any GammaTables
    private let lock = NSLock()
    private var baselines: [CGDirectDisplayID: GammaTable] = [:]
    private var applied: [CGDirectDisplayID: BrightnessLevel] = [:]

    public init(tables: any GammaTables) {
        self.tables = tables
    }

    public func probe(_ id: CGDirectDisplayID) -> BrightnessProbe {
        tables.canDrive(id) ? .supported(readable: true) : .unsupported
    }

    /// What Pitch last applied: gamma has no hardware to ask, so the answer is
    /// Pitch's own record, and "full" for a display it has not touched.
    public func level(for id: CGDirectDisplayID) throws -> BrightnessLevel? {
        lock.lock()
        defer { lock.unlock() }
        return applied[id] ?? .full
    }

    public func setLevel(_ level: BrightnessLevel, for id: CGDirectDisplayID) throws {
        lock.lock()
        defer { lock.unlock() }

        // The baseline is captured once, before the first change, and never again
        // while Pitch's own table may be live: capturing then would take the
        // dimmed table as "normal" and dim it a second time.
        let baseline: GammaTable
        if let held = baselines[id] {
            baseline = held
        } else {
            guard let captured = tables.capture(id) else {
                throw DisplayError.brightnessUnsupported(id)
            }
            baselines[id] = captured
            baseline = captured
        }

        let code = tables.apply(baseline.scaled(by: level.value), to: id)
        guard code == 0 else { throw DisplayError.brightnessWriteFailed(id, code: code) }
        applied[id] = level
    }

    /// Hands every display back to the system and forgets everything. Called on
    /// quit, and on any display reconfiguration.
    public func restoreAll() {
        lock.lock()
        defer { lock.unlock() }
        baselines.removeAll()
        applied.removeAll()
        tables.restoreSystemSettings()
    }

    /// A reconfiguration resets to the system setting rather than trying to
    /// carry dimming across it: the ID may now be a different monitor, and the
    /// baseline cannot be re-captured safely while a dimmed table may be live.
    /// Only acts if Pitch had dimmed something, so an idle backend never
    /// disturbs another tool's colour adjustments.
    public func configurationDidChange() {
        lock.lock()
        let hadDimmed = !applied.isEmpty
        lock.unlock()
        if hadDimmed { restoreAll() }
    }

    /// Quit puts the screen back, but only if Pitch dimmed it: an unconditional
    /// `CGDisplayRestoreColorSyncSettings` would also reset a colour adjustment
    /// some other tool had applied and Pitch never touched.
    public func shutDown() {
        configurationDidChange()
    }
}

/// The real thing. Not unit-tested: it is exactly the part that touches the
/// screen, and is checked by a human at the keyboard (spec §18.9).
public struct CoreGraphicsGamma: GammaTables {
    public init() {}

    public func canDrive(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayIsActive(id) != 0 && CGDisplayGammaTableCapacity(id) > 0
    }

    public func capture(_ id: CGDirectDisplayID) -> GammaTable? {
        let capacity = CGDisplayGammaTableCapacity(id)
        guard capacity > 0 else { return nil }
        var red = [CGGammaValue](repeating: 0, count: Int(capacity))
        var green = red
        var blue = red
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(id, capacity, &red, &green, &blue, &count) == .success,
            count > 0
        else { return nil }
        let n = Int(count)
        return GammaTable(
            red: Array(red.prefix(n)), green: Array(green.prefix(n)), blue: Array(blue.prefix(n)))
    }

    public func apply(_ table: GammaTable, to id: CGDirectDisplayID) -> Int32 {
        CGSetDisplayTransferByTable(
            id, UInt32(table.red.count), table.red, table.green, table.blue).rawValue
    }

    public func restoreSystemSettings() {
        CGDisplayRestoreColorSyncSettings()
    }
}
