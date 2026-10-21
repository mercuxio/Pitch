import CoreGraphics

/// How bright a display is, as a fraction of its own range (spec §18.3).
///
/// Always 0...1 regardless of the mechanism underneath: a DDC monitor may report
/// a maximum other than 100, and gamma has no native scale at all. Converting to
/// and from a backend's own units is that backend's job.
public struct BrightnessLevel: Equatable, Sendable {
    public let value: Double

    /// Clamps to 0...1. A non-finite value becomes 1: garbage from a failed read
    /// must never turn into a request to go dark.
    public init(_ value: Double) {
        guard value.isFinite else {
            self.value = 1
            return
        }
        self.value = min(1, max(0, value))
    }

    public static let full = BrightnessLevel(1)
}

/// The mechanism that actually changes the picture (spec §18.2).
public enum BrightnessMethod: Equatable, Sendable, CaseIterable {
    /// Private `DisplayServices`: Apple panels.
    case appleDisplay
    /// DDC/CI over I²C: the monitor's own backlight.
    case ddc
    /// A scaled gamma table: software dimming, any display.
    case gamma

    /// The lowest level the slider may reach (spec §18.6).
    ///
    /// Per mechanism, so that no slider position is an unreadable screen: gamma
    /// crushes everything toward black and runs out of usable picture far sooner
    /// than a backlight does. Starting values, to be tuned on hardware.
    public var floor: Double {
        switch self {
        case .appleDisplay, .ddc: return 0.05
        case .gamma: return 0.20
        }
    }

    /// `level` raised to this method's floor.
    public func clamped(_ level: BrightnessLevel) -> BrightnessLevel {
        BrightnessLevel(max(level.value, floor))
    }
}

/// What a backend found out about one display. Producing it never writes.
public enum BrightnessProbe: Equatable, Sendable {
    case unsupported
    /// `readable` is false for a monitor that accepts writes but never answers a
    /// read: usable, but the slider can only show what Pitch last set.
    case supported(readable: Bool)
}

public protocol BrightnessBackend: Sendable {
    var method: BrightnessMethod { get }

    /// Whether this backend can drive `id`. **Must not change anything on the
    /// display** — `displayctl doctor` runs probes, and a probe that wrote would
    /// make the diagnostic unsafe to run unattended (spec §18.4).
    func probe(_ id: CGDirectDisplayID) -> BrightnessProbe

    /// The live level, or `nil` when this display cannot be read back.
    func level(for id: CGDirectDisplayID) throws -> BrightnessLevel?

    func setLevel(_ level: BrightnessLevel, for id: CGDirectDisplayID) throws

    /// The display configuration changed (replug, wake, resolution change). A
    /// backend holding state keyed by display ID must drop or reset it: the ID
    /// may now name a different monitor. Default: nothing to drop.
    func configurationDidChange()
}

extension BrightnessBackend {
    public func configurationDidChange() {}
}
