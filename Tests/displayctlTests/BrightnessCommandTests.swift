import CoreGraphics
import Testing

@testable import DisplayCore
@testable import displayctl

// MARK: - Parsing

@Test func brightnessNeedsASubcommand() {
    #expect(throws: ParseError.self) { try ArgumentParser.parse(["brightness"]) }
    #expect(throws: ParseError.self) { try ArgumentParser.parse(["brightness", "dim"]) }
}

@Test func brightnessListTakesNoArguments() throws {
    #expect(try ArgumentParser.parse(["brightness", "list"]) == .brightness(.list))
    #expect(throws: ParseError.self) { try ArgumentParser.parse(["brightness", "list", "--all"]) }
}

@Test func brightnessGetDefaultsToNoDisplayAndAcceptsOne() throws {
    #expect(
        try ArgumentParser.parse(["brightness", "get"]) == .brightness(.get(displayIndex: nil)))
    #expect(
        try ArgumentParser.parse(["brightness", "get", "--display", "2"])
            == .brightness(.get(displayIndex: 2)))
}

@Test func brightnessSetParsesAPercentWithOrWithoutTheSign() throws {
    let plain = try ArgumentParser.parse(["brightness", "set", "60"])
    let signed = try ArgumentParser.parse(["brightness", "set", "60%", "--display", "2"])

    #expect(plain == .brightness(.set(BrightnessSetOptions(percent: 60))))
    #expect(signed == .brightness(.set(BrightnessSetOptions(percent: 60, displayIndex: 2))))
    #expect(
        try ArgumentParser.parse(["brightness", "set", "12.5"])
            == .brightness(.set(BrightnessSetOptions(percent: 12.5))))
}

@Test func brightnessSetRefusesWhatItWouldHaveToGuessAt() {
    // A typo of 600 must not quietly mean "full", and nan must not reach a backend.
    for bad in ["600", "-5", "abc", "", "nan", "inf", "101"] {
        #expect(throws: ParseError.self, "level '\(bad)'") {
            try ArgumentParser.parse(["brightness", "set", bad])
        }
    }
    #expect(throws: ParseError.self) { try ArgumentParser.parse(["brightness", "set"]) }
}

@Test func brightnessSetAcceptsTheEdges() throws {
    #expect(
        try ArgumentParser.parse(["brightness", "set", "0"])
            == .brightness(.set(BrightnessSetOptions(percent: 0))))
    #expect(
        try ArgumentParser.parse(["brightness", "set", "100"])
            == .brightness(.set(BrightnessSetOptions(percent: 100))))
}

@Test func brightnessRejectsARepeatedDisplayFlag() {
    // The same protection `set` has: a repeat is last-wins otherwise, and this one
    // writes to a screen the user did not name.
    #expect(throws: ParseError.self) {
        try ArgumentParser.parse(
            ["brightness", "set", "50", "--display", "1", "--display", "2"])
    }
}

// MARK: - Running

private func twoDisplays() -> CLIFakeEnumerator {
    let enumerator = CLIFakeEnumerator()
    enumerator.ids = [10, 20]
    return enumerator
}

@Test func listShowsEachDisplaysMechanismAndLevel() throws {
    let ddc = CLIFakeBrightnessBackend(.ddc, level: BrightnessLevel(0.4))
    ddc.probeResult = .supported(readable: true)
    let router = BrightnessRouter(backends: [ddc])

    let text = try runBrightnessList(enumerator: twoDisplays(), router: router)

    #expect(text.contains("[1] Display 10  monitor hardware (DDC/CI)  40%"))
    #expect(text.contains("[2] Display 20  monitor hardware (DDC/CI)  40%"))
}

@Test func listSaysWriteOnlyInsteadOfInventingALevel() throws {
    let router = BrightnessRouter(backends: [
        CLIFakeBrightnessBackend(.ddc, probe: .supported(readable: false))
    ])

    let text = try runBrightnessList(enumerator: CLIFakeEnumerator(), router: router)

    #expect(text.contains("write-only"))
    #expect(!text.contains("%"))
}

@Test func listSaysSoWhenNoBackendCanDriveADisplay() throws {
    let router = BrightnessRouter(backends: [
        CLIFakeBrightnessBackend(.ddc, probe: .unsupported)
    ])

    #expect(
        try runBrightnessList(enumerator: CLIFakeEnumerator(), router: router)
            .contains("no brightness control"))
}

@Test func listNeverReportsAGammaLevelAFreshProcessCannotKnow() throws {
    // Gamma "reads" 100% for anything this process has not touched, which is
    // wrong whenever another run (or the app) has dimmed the screen.
    let router = BrightnessRouter(backends: [
        CLIFakeBrightnessBackend(.gamma, level: BrightnessLevel.full)
    ])

    let text = try runBrightnessList(enumerator: CLIFakeEnumerator(), router: router)

    #expect(text.contains("software dimming"))
    #expect(!text.contains("100%"))
}

@Test func listAndGetNeverWrite() throws {
    let backend = CLIFakeBrightnessBackend(.ddc, level: BrightnessLevel(0.4))
    let router = BrightnessRouter(backends: [backend])

    _ = try runBrightnessList(enumerator: twoDisplays(), router: router)
    _ = try runBrightnessGet(displayIndex: 2, enumerator: twoDisplays(), router: router)

    #expect(backend.writes.isEmpty)
}

@Test func getDefaultsToDisplayOneAndNamesTheOneItAnswersFor() throws {
    let router = BrightnessRouter(backends: [
        CLIFakeBrightnessBackend(.appleDisplay, level: BrightnessLevel(0.5))
    ])

    let first = try runBrightnessGet(displayIndex: nil, enumerator: twoDisplays(), router: router)
    let second = try runBrightnessGet(displayIndex: 2, enumerator: twoDisplays(), router: router)

    #expect(first.hasPrefix("[1] Display 10"))
    #expect(second.hasPrefix("[2] Display 20"))
}

@Test func getRejectsADisplayThatIsNotThere() {
    #expect(throws: ParseError.self) {
        try runBrightnessGet(
            displayIndex: 3, enumerator: twoDisplays(),
            router: BrightnessRouter(backends: []))
    }
}

@Test func setWritesTheRequestedFractionToTheChosenDisplay() throws {
    let backend = CLIFakeBrightnessBackend(.ddc)
    let router = BrightnessRouter(backends: [backend])

    let text = try runBrightnessSet(
        BrightnessSetOptions(percent: 60, displayIndex: 2),
        enumerator: twoDisplays(), router: router)

    #expect(backend.writes.count == 1)
    #expect(backend.writes.first?.id == 20)
    #expect(backend.writes.first?.level == BrightnessLevel(0.6))
    #expect(text == "[2] Display 20: brightness set to 60% via monitor hardware (DDC/CI).")
}

@Test func setSaysWhenTheFloorRaisedTheRequest() throws {
    let backend = CLIFakeBrightnessBackend(.ddc)

    let text = try runBrightnessSet(
        BrightnessSetOptions(percent: 0),
        enumerator: CLIFakeEnumerator(), router: BrightnessRouter(backends: [backend]))

    #expect(backend.writes.first?.level == BrightnessLevel(BrightnessMethod.ddc.floor))
    #expect(text.contains("5%"))
    #expect(text.contains("lowest this method goes"))
}

@Test func setRefusesSoftwareDimmingAndWritesNothing() {
    // It would dim and then undo itself when this process exits.
    let backend = CLIFakeBrightnessBackend(.gamma)
    let router = BrightnessRouter(backends: [backend])

    #expect(throws: BrightnessCommandError.softwareDimmingDoesNotOutliveTheCommand(displayIndex: 1)) {
        try runBrightnessSet(
            BrightnessSetOptions(percent: 50), enumerator: CLIFakeEnumerator(), router: router)
    }
    #expect(backend.writes.isEmpty)
}

@Test func setOnADisplayNoBackendCanDriveFailsWithoutWriting() {
    let backend = CLIFakeBrightnessBackend(.ddc, probe: .unsupported)

    #expect(throws: DisplayError.brightnessUnsupported(1)) {
        try runBrightnessSet(
            BrightnessSetOptions(percent: 50), enumerator: CLIFakeEnumerator(),
            router: BrightnessRouter(backends: [backend]))
    }
    #expect(backend.writes.isEmpty)
}

@Test func theGammaRefusalNamesTheDisplayAndPointsAtTheApp() {
    let text = Renderer.describe(
        BrightnessCommandError.softwareDimmingDoesNotOutliveTheCommand(displayIndex: 2))

    #expect(text.contains("display 2"))
    #expect(text.contains("Pitch app"))
}

// MARK: - Doctor

private func brightnessSection(of report: String) -> String {
    report.components(separatedBy: "Brightness\n").last ?? ""
}

@Test func doctorReportsEachDisplaysBrightnessRouteWithoutWriting() throws {
    let backend = CLIFakeBrightnessBackend(.ddc, probe: .supported(readable: false))
    let enumerator = CLIFakeEnumerator()
    enumerator.modesByID[1] = []

    let report = try Doctor.report(
        enumerator: enumerator, brightness: BrightnessRouter(backends: [backend]))

    #expect(brightnessSection(of: report).contains("[1] Display 1: monitor hardware (DDC/CI), write-only"))
    #expect(backend.writes.isEmpty)
}

@Test func doctorSaysWhenADisplayHasNoBrightnessControl() throws {
    let enumerator = CLIFakeEnumerator()
    enumerator.modesByID[1] = []

    let report = try Doctor.report(
        enumerator: enumerator, brightness: BrightnessRouter(backends: []))

    #expect(brightnessSection(of: report).contains("no control available"))
}
