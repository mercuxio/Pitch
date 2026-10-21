import CoreGraphics
import Foundation

@testable import DisplayCore

/// A scripted `BrightnessBackend`. Never touches a display.
final class FakeBrightnessBackend: BrightnessBackend, @unchecked Sendable {
    let method: BrightnessMethod
    var probeResult: BrightnessProbe
    var storedLevel: BrightnessLevel?
    var writeError: Error?

    private(set) var probeCount = 0
    private(set) var writes: [(level: BrightnessLevel, id: CGDirectDisplayID)] = []

    init(
        _ method: BrightnessMethod,
        probe: BrightnessProbe = .supported(readable: true),
        level: BrightnessLevel? = nil
    ) {
        self.method = method
        self.probeResult = probe
        self.storedLevel = level
    }

    func probe(_ id: CGDirectDisplayID) -> BrightnessProbe {
        probeCount += 1
        return probeResult
    }

    func level(for id: CGDirectDisplayID) throws -> BrightnessLevel? { storedLevel }

    func setLevel(_ level: BrightnessLevel, for id: CGDirectDisplayID) throws {
        if let writeError { throw writeError }
        writes.append((level, id))
        storedLevel = level
    }
}

/// Gamma tables held in memory. Never touches a display.
final class FakeGammaTables: GammaTables, @unchecked Sendable {
    var drivable: Set<CGDirectDisplayID> = [1]
    var system = GammaTable(red: [0, 0.5, 1], green: [0, 0.5, 1], blue: [0, 0.5, 1])
    var applyCode: Int32 = 0

    private(set) var captureCount = 0
    private(set) var applications: [(id: CGDirectDisplayID, table: GammaTable)] = []
    private(set) var restoreCount = 0
    /// What a real display would currently be showing.
    private(set) var live: [CGDirectDisplayID: GammaTable] = [:]

    func canDrive(_ id: CGDirectDisplayID) -> Bool { drivable.contains(id) }

    func capture(_ id: CGDirectDisplayID) -> GammaTable? {
        captureCount += 1
        return live[id] ?? system
    }

    func apply(_ table: GammaTable, to id: CGDirectDisplayID) -> Int32 {
        applications.append((id, table))
        if applyCode == 0 { live[id] = table }
        return applyCode
    }

    func restoreSystemSettings() {
        restoreCount += 1
        live.removeAll()
    }
}

/// DisplayServices calls scripted per display. Never touches a panel.
final class FakeDisplayServices: DisplayServicesCalls, @unchecked Sendable {
    var isAvailable = true
    var panels: [CGDirectDisplayID: Float] = [1: 0.5]
    var getStatus: Int32 = 0
    var setStatus: Int32 = 0

    private(set) var sets: [(id: CGDirectDisplayID, value: Float)] = []

    func get(_ id: CGDirectDisplayID) -> (status: Int32, value: Float) {
        guard let value = panels[id] else { return (-1, 0) }
        return (getStatus, value)
    }

    func set(_ id: CGDirectDisplayID, _ value: Float) -> Int32 {
        sets.append((id, value))
        if setStatus == 0 { panels[id] = value }
        return setStatus
    }
}
