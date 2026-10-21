import AppKit

/// One display's brightness slider: a label and a slider on a single line.
///
/// Reports every change as it happens, tagged with whether the user is still
/// dragging. The controller writes on both, but persists only on `.committed`,
/// so a drag costs one disk write at the end rather than one per pixel.
@MainActor
final class BrightnessRowView: NSView {
    enum Phase {
        case dragging
        case committed
    }

    private enum Metrics {
        static let height: CGFloat = 30
        /// Matches the picker and footer: the visible edge of their content.
        static let visibleInset: CGFloat = 14
        static let gap: CGFloat = 8
        static let minimumSliderWidth: CGFloat = 120
    }

    private let slider: NSSlider
    private let onChange: (Double, Phase) -> Void

    init(model: BrightnessRowModel, onChange: @escaping (Double, Phase) -> Void) {
        self.onChange = onChange
        slider = NSSlider(
            value: model.value, minValue: model.floor, maxValue: 1, target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: 220, height: Metrics.height))

        slider.target = self
        slider.action = #selector(moved)
        slider.isContinuous = true
        slider.controlSize = .small
        slider.isEnabled = model.isEnabled
        slider.toolTip = model.tooltip
        slider.setAccessibilityLabel(model.title)

        let label = NSTextField(labelWithString: model.title)
        label.font = .menuFont(ofSize: 12)
        label.textColor = model.isEnabled ? .labelColor : .disabledControlTextColor
        label.toolTip = model.tooltip
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)

        for view in [label, slider] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Metrics.height),
            label.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: Metrics.visibleInset),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            slider.leadingAnchor.constraint(
                equalTo: label.trailingAnchor, constant: Metrics.gap),
            slider.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -Metrics.visibleInset),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),
            slider.widthAnchor.constraint(greaterThanOrEqualToConstant: Metrics.minimumSliderWidth),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// An `NSSlider` sends its action for the press, each drag, and the release.
    /// Anything that is not the press or a drag — the release, or an arrow key —
    /// is the user settling on a value.
    @objc private func moved() {
        let type = NSApp.currentEvent?.type
        let stillDragging = type == .leftMouseDown || type == .leftMouseDragged
        onChange(slider.doubleValue, stillDragging ? .dragging : .committed)
    }
}
