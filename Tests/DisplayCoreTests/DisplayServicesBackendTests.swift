import CoreGraphics
import Testing

@testable import DisplayCore

@Test func aPanelThatAnswersIsSupportedAndReadable() {
    let backend = DisplayServicesBackend(calls: FakeDisplayServices())

    #expect(backend.probe(1) == .supported(readable: true))
}

@Test func aDisplayTheCallsDoNotKnowIsUnsupported() {
    // The third-party monitor case: it must fall through to DDC, not be claimed here.
    #expect(DisplayServicesBackend(calls: FakeDisplayServices()).probe(2) == .unsupported)
}

@Test func missingSymbolsMakeTheBackendUnsupportedNotBroken() {
    let calls = FakeDisplayServices()
    calls.isAvailable = false

    #expect(DisplayServicesBackend(calls: calls).probe(1) == .unsupported)
}

@Test func aFailingReadIsUnsupportedEvenIfItLeftAValueBehind() {
    let calls = FakeDisplayServices()
    calls.getStatus = -1

    #expect(DisplayServicesBackend(calls: calls).probe(1) == .unsupported)
}

@Test func aNonsenseValueIsNotTakenAsASupportedPanel() {
    for bad: Float in [-0.1, 1.5, .nan, .infinity] {
        let calls = FakeDisplayServices()
        calls.panels[1] = bad

        #expect(DisplayServicesBackend(calls: calls).probe(1) == .unsupported, "value \(bad)")
    }
}

@Test func probingNeverWrites() {
    let calls = FakeDisplayServices()

    _ = DisplayServicesBackend(calls: calls).probe(1)

    #expect(calls.sets.isEmpty)
}

@Test func theLevelIsWhatThePanelReports() throws {
    let calls = FakeDisplayServices()
    calls.panels[1] = 0.25

    #expect(try DisplayServicesBackend(calls: calls).level(for: 1) == BrightnessLevel(0.25))
}

@Test func readingAPanelThatStoppedAnsweringThrowsRatherThanInventingALevel() {
    #expect(throws: DisplayError.brightnessUnsupported(2)) {
        try DisplayServicesBackend(calls: FakeDisplayServices()).level(for: 2)
    }
}

@Test func settingWritesTheFractionToThatDisplay() throws {
    let calls = FakeDisplayServices()
    calls.panels[2] = 1

    try DisplayServicesBackend(calls: calls).setLevel(BrightnessLevel(0.4), for: 2)

    #expect(calls.sets.count == 1)
    #expect(calls.sets.first?.id == 2)
    #expect(calls.sets.first?.value == 0.4)
}

@Test func aRefusedWriteCarriesTheStatusCode() {
    let calls = FakeDisplayServices()
    calls.setStatus = -536870212

    #expect(throws: DisplayError.brightnessWriteFailed(1, code: -536870212)) {
        try DisplayServicesBackend(calls: calls).setLevel(BrightnessLevel(0.4), for: 1)
    }
}

@Test func theRouterPrefersThePanelAndFallsBackToGammaForEverythingElse() throws {
    let calls = FakeDisplayServices()
    let tables = FakeGammaTables()
    tables.drivable = [1, 2]
    let router = BrightnessRouter(backends: [
        DisplayServicesBackend(calls: calls), GammaBackend(tables: tables),
    ])

    #expect(router.route(for: 1) == BrightnessRoute(method: .appleDisplay, readable: true))
    #expect(router.route(for: 2) == BrightnessRoute(method: .gamma, readable: true))
}
