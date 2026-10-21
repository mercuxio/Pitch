import DisplayCore

/// What one display's brightness slider shows (spec §18.8), decided without
/// AppKit so the wording and the enabled state can be tested.
struct BrightnessRowModel: Equatable {
    let title: String
    /// `nil` when there is nothing to explain.
    let tooltip: String?
    /// The slider's lower bound: the mechanism's floor, so that no position is
    /// an unreadable screen (spec §18.6).
    let floor: Double
    /// Within `floor...1`.
    let value: Double
    let isEnabled: Bool

    /// The slider's value as the reader sees it. The slider's own range starts at
    /// the floor, so the label shows the true level and never a rescaled one.
    static func percentText(_ value: Double) -> String {
        "\(Int((BrightnessLevel(value).value * 100).rounded()))%"
    }

    /// - Parameters:
    ///   - level: the live level, when the display can be read back.
    ///   - remembered: the level Pitch last set on a write-only monitor.
    ///   - failure: the last write error for this display. It disables the row
    ///     and explains itself in the tooltip; it never raises an alert.
    init(route: BrightnessRoute, level: BrightnessLevel?, remembered: Double?, failure: Error?) {
        let method = route.method
        floor = method.floor

        // A write-only monitor with nothing remembered is assumed to be at full:
        // the first drag then starts from the top rather than from a guess.
        let shown = level?.value ?? remembered ?? 1
        value = max(BrightnessLevel(shown).value, method.floor)

        switch method {
        case .appleDisplay, .ddc: title = "Brightness"
        case .gamma: title = "Dimming"
        }

        if let failure {
            isEnabled = false
            tooltip = ErrorText.describe(failure)
        } else {
            isEnabled = true
            tooltip = method == .gamma
                ? "Reduces brightness in software and does not deepen blacks."
                : nil
        }
    }
}
