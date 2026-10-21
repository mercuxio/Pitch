import Testing

@testable import DisplayCore
@testable import Pitch

private func row(
    _ method: BrightnessMethod, readable: Bool = true,
    level: Double? = nil, remembered: Double? = nil, failure: Error? = nil
) -> BrightnessRowModel {
    BrightnessRowModel(
        route: BrightnessRoute(method: method, readable: readable),
        level: level.map(BrightnessLevel.init), remembered: remembered, failure: failure)
}

@Test func appleAndDDCDisplaysAreLabelledBrightness() {
    #expect(row(.appleDisplay).title == "Brightness")
    #expect(row(.ddc).title == "Brightness")
}

@Test func softwareDimmingIsLabelledDimmingAndSaysWhatItDoes() {
    let model = row(.gamma)

    #expect(model.title == "Dimming")
    #expect(model.tooltip == "Reduces brightness in software and does not deepen blacks.")
}

@Test func aBacklightRowHasNoTooltipToExplain() {
    #expect(row(.ddc).tooltip == nil)
}

@Test func theSliderFloorIsTheMechanismsOwn() {
    #expect(row(.ddc).floor == BrightnessMethod.ddc.floor)
    #expect(row(.gamma).floor == BrightnessMethod.gamma.floor)
}

@Test func theLiveLevelIsShownWhenItCanBeRead() {
    #expect(row(.ddc, level: 0.6, remembered: 0.2).value == 0.6)
}

@Test func aWriteOnlyMonitorShowsWhatPitchLastSet() {
    #expect(row(.ddc, readable: false, remembered: 0.3).value == 0.3)
}

@Test func aWriteOnlyMonitorWithNothingRememberedStartsAtFull() {
    #expect(row(.ddc, readable: false).value == 1)
}

@Test func aLevelBelowTheFloorIsShownAtTheFloor() {
    // Gamma cannot go below 0.2, so a remembered 0.05 must not sit the thumb
    // somewhere the slider cannot reach.
    #expect(row(.gamma, level: 0.05).value == BrightnessMethod.gamma.floor)
}

@Test func aFailureDisablesTheRowAndExplainsItInTheTooltip() {
    let model = row(.ddc, level: 0.5, failure: DisplayError.brightnessWriteFailed(1, code: 5))

    #expect(!model.isEnabled)
    #expect(model.tooltip == "The display didn't accept the brightness change.")
}

@Test func aHealthyRowIsEnabled() {
    #expect(row(.appleDisplay, level: 0.5).isEnabled)
}
