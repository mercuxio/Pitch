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
