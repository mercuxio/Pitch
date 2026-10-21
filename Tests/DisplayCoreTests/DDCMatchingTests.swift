import CoreGraphics
import Testing

@testable import DisplayCore

private let lg = DisplayHardwareID(vendor: 7789, model: 23305, serial: 79350)
private let samsung = DisplayHardwareID(vendor: 19501, model: 57513, serial: 0)

@Test func aDisplayTakesTheServiceCarryingItsHardwareID() {
    let assigned = DDCMatching.assign(
        displays: [2: lg, 5: samsung],
        services: [("a", samsung), ("b", lg)])

    #expect(assigned == [2: "b", 5: "a"])
}

@Test func aDisplayWithNoServiceIsLeftOut() {
    let assigned = DDCMatching.assign(displays: [2: lg], services: [("a", samsung)])

    #expect(assigned.isEmpty)
}

@Test func twoIdenticalDisplaysDeclineRatherThanGuess() {
    // Same vendor, model and serial: nothing here says which service is which,
    // and dimming the wrong monitor is worse than falling back to gamma.
    let assigned = DDCMatching.assign(
        displays: [2: lg, 3: lg], services: [("a", lg), ("b", lg)])

    #expect(assigned.isEmpty)
}

@Test func oneDisplayAgainstTwoMatchingServicesDeclines() {
    let assigned = DDCMatching.assign(displays: [2: lg], services: [("a", lg), ("b", lg)])

    #expect(assigned.isEmpty)
}

@Test func anAmbiguousPairDoesNotBlockAnUnambiguousNeighbour() {
    let assigned = DDCMatching.assign(
        displays: [2: lg, 3: lg, 5: samsung],
        services: [("a", lg), ("b", lg), ("c", samsung)])

    #expect(assigned == [5: "c"])
}

@Test func twoMatchingDisplaysAgainstOneServiceDecline() {
    // The converse of the case above: the single service cannot belong to both.
    let assigned = DDCMatching.assign(displays: [2: lg, 3: lg], services: [("a", lg)])

    #expect(assigned.isEmpty)
}
