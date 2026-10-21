import CoreGraphics
import Foundation
import DisplayCore

/// Field diagnostics for the failure mode of spec §4.1.
///
/// Building the enumeration options from a string literal instead of the
/// linked constant returns a shorter list with no HiDPI modes — no error, no
/// warning, just a wrong answer. On a machine you cannot inspect, this report
/// is how you find out.
public enum Doctor {
    public static func report(
        enumerator: DisplayEnumerating,
        brightness router: BrightnessRouter = .system(),
        ddcDiagnosis: ((CGDirectDisplayID) -> DDCDiagnosis)? = nil
    ) throws -> String {
        var lines: [String] = []

        lines.append("displayctl doctor")
        lines.append("")
        lines.append("HiDPI enumeration key")
        lines.append("  kCGDisplayShowDuplicateLowResolutionModes = "
            + "\"\(kCGDisplayShowDuplicateLowResolutionModes as String)\"")
        lines.append("  expected: \"kCGDisplayResolution\"")

        if (kCGDisplayShowDuplicateLowResolutionModes as String) != "kCGDisplayResolution" {
            lines.append("  WARNING: the constant changed value. HiDPI enumeration is")
            lines.append("           unverified on this OS version.")
        }

        lines.append("")
        lines.append("Displays")

        var sawAnyHiDPI = false
        for (offset, id) in try enumerator.onlineDisplayIDs().enumerated() {
            let device = try enumerator.device(for: id)
            let modes = try enumerator.modes(for: id)
            let hidpi = modes.filter(\.isHiDPI)
            sawAnyHiDPI = sawAnyHiDPI || !hidpi.isEmpty

            lines.append("  [\(offset + 1)] \(device.localizedName) (ID \(id))")
            lines.append("      \(modes.count) modes, \(hidpi.count) HiDPI, "
                + "\(modes.filter { !$0.isSafe }.count) unsafe, "
                + "\(modes.filter(\.isStretched).count) stretched")

            if let current = try? enumerator.currentMode(for: id) {
                lines.append("      current: \(current.pointWidth)x\(current.pointHeight)"
                    + " (\(current.pixelWidth)x\(current.pixelHeight) px)")
            }
        }

        if !sawAnyHiDPI {
            lines.append("")
            lines.append("WARNING: no HiDPI modes on any display. On a Retina or scaled")
            lines.append("         external display this means enumeration is broken —")
            lines.append("         see the HiDPI enumeration key above.")
        }

        // Probes only: nothing here writes to a display or a monitor.
        lines.append("")
        lines.append("Brightness")
        for (offset, id) in try enumerator.onlineDisplayIDs().enumerated() {
            let name = try enumerator.device(for: id).localizedName
            let route = router.route(for: id)
            let how = route.map {
                Renderer.methodName($0.method) + ($0.readable ? "" : ", write-only")
            } ?? "no control available"
            lines.append("  [\(offset + 1)] \(name): \(how)")
            // Why a display that isn't Apple's own ended up on software dimming.
            if let ddcDiagnosis, route?.method != .appleDisplay, route?.method != .ddc {
                lines.append("      DDC: \(describe(ddcDiagnosis(id)))")
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    static func describe(_ diagnosis: DDCDiagnosis) -> String {
        switch diagnosis {
        case .noService:
            return "no IOAVService matched this display"
        case .transportFailed(let code):
            return "the I2C transfer failed (code \(code))"
        case .unparseable(let error, let bytes):
            return "reply did not parse (\(error)): \(hex(bytes))"
        case .badChecksum(let bytes):
            return "reply failed its checksum: \(hex(bytes))"
        case .zeroMaximum(let bytes):
            return "reply reports a maximum of 0: \(hex(bytes))"
        case .answered(let current, let maximum):
            return "answered, \(current) of \(maximum)"
        }
    }
}
