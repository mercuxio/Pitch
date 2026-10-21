import CoreGraphics
import Testing

@testable import DisplayCore

private func backend(
    _ link: FakeDDCLink?, id: CGDirectDisplayID = 1
) -> (backend: DDCBackend, links: FakeDDCLinks) {
    let links = FakeDDCLinks(link.map { [id: $0] } ?? [:])
    return (DDCBackend(links: links), links)
}

private let answering = FakeDDCLink.luminanceReply(current: 30, maximum: 100)

@Test func aMonitorThatAnswersIsSupportedAndReadable() {
    let (ddc, _) = backend(FakeDDCLink(replies: [answering]))

    #expect(ddc.probe(1) == .supported(readable: true))
}

@Test func aDisplayWithNoLinkIsUnsupported() {
    let (ddc, _) = backend(nil)

    #expect(ddc.probe(1) == .unsupported)
}

@Test func theRecordedFABufferFromTheLGIsNotAnAnswer() {
    // What the development machine's LG actually returned for every delay and
    // offset tried: twelve 0xFA bytes. Claiming DDC on that would leave a slider
    // that moves nothing instead of falling through to gamma.
    let silent = FakeDDCLink(replies: [[UInt8](repeating: 0xFA, count: 12)])
    let (ddc, _) = backend(silent)

    #expect(ddc.probe(1) == .unsupported)
}

@Test func aReplyWithABadChecksumIsNotAnAnswer() {
    let corrupt = FakeDDCLink.luminanceReply(current: 30, maximum: 100, corruptChecksum: true)
    let (ddc, _) = backend(FakeDDCLink(replies: [corrupt]))

    #expect(ddc.probe(1) == .unsupported)
}

@Test func aReplyForADifferentFeatureIsNotAnAnswer() {
    var wrong = FakeDDCLink.luminanceReply(current: 30, maximum: 100)
    wrong[3] = 0x12
    let (ddc, _) = backend(FakeDDCLink(replies: [wrong]))

    #expect(ddc.probe(1) == .unsupported)
}

@Test func aReplyReportingAMaximumOfZeroIsNotAnAnswer() {
    let zero = FakeDDCLink.luminanceReply(current: 0, maximum: 0)
    let (ddc, _) = backend(FakeDDCLink(replies: [zero]))

    #expect(ddc.probe(1) == .unsupported)
}

@Test func aTransportFailureIsNotAnAnswer() {
    let link = FakeDDCLink(replies: [answering])
    link.requestStatus = -1
    let (ddc, _) = backend(link)

    #expect(ddc.probe(1) == .unsupported)
}

@Test func aSingleLostFrameDoesNotSendAWorkingMonitorToGamma() {
    // Silent first, then a good reply: the second probe attempt rescues it.
    let link = FakeDDCLink(replies: [[], answering])
    let (ddc, _) = backend(link)

    #expect(ddc.probe(1) == .supported(readable: true))
    #expect(link.requestCount == 2)
}

@Test func probingAsksTwiceAtMostAndOnlyEverReads() {
    let link = FakeDDCLink(replies: [[]])
    let (ddc, _) = backend(link)

    _ = ddc.probe(1)

    #expect(link.requestCount == DDCBackend.probeAttempts)
    // A probe must not change what the monitor shows.
    #expect(link.sent.isEmpty)
}

@Test func levelIsTheMonitorsCurrentOverItsMaximum() throws {
    let (ddc, _) = backend(FakeDDCLink(replies: [FakeDDCLink.luminanceReply(current: 25, maximum: 50)]))

    #expect(try ddc.level(for: 1) == BrightnessLevel(0.5))
}

@Test func writesScaleAgainstTheMonitorsOwnMaximum() throws {
    let link = FakeDDCLink(replies: [FakeDDCLink.luminanceReply(current: 10, maximum: 200)])
    let (ddc, _) = backend(link)
    _ = ddc.probe(1)

    try ddc.setLevel(BrightnessLevel(0.5), for: 1)

    #expect(link.sent == [DDC.setVCP(DDC.luminance, value: 100)])
}

@Test func aWriteWithoutALearnedMaximumReadsOneFirst() throws {
    let link = FakeDDCLink(replies: [FakeDDCLink.luminanceReply(current: 10, maximum: 200)])
    let (ddc, _) = backend(link)

    try ddc.setLevel(BrightnessLevel(1), for: 1)

    #expect(link.sent == [DDC.setVCP(DDC.luminance, value: 200)])
}

@Test func aWriteThatCannotLearnTheMaximumRefusesRatherThanAssumes100() {
    let (ddc, _) = backend(FakeDDCLink(replies: [[]]))

    #expect(throws: DisplayError.brightnessUnsupported(1)) {
        try ddc.setLevel(BrightnessLevel(0.5), for: 1)
    }
}

@Test func aFailedWriteCarriesTheTransportCode() {
    let link = FakeDDCLink(replies: [answering])
    let (ddc, _) = backend(link)
    _ = ddc.probe(1)
    link.sendStatus = -7

    #expect(throws: DisplayError.brightnessWriteFailed(1, code: -7)) {
        try ddc.setLevel(BrightnessLevel(0.5), for: 1)
    }
}

@Test func anUnansweredReadIsNilNotAnError() throws {
    let (ddc, _) = backend(FakeDDCLink(replies: [answering, []]))
    _ = ddc.probe(1)

    #expect(try ddc.level(for: 1) == nil)
}

@Test func afterRepeatedSilenceTheBusIsNoLongerAsked() throws {
    let link = FakeDDCLink(replies: [answering, []])
    let (ddc, _) = backend(link)
    _ = ddc.probe(1)

    for _ in 0..<DDCBackend.readFailureLimit { _ = try ddc.level(for: 1) }
    let before = link.requestCount
    _ = try ddc.level(for: 1)

    #expect(link.requestCount == before)
}

@Test func aGoodReadClearsTheFailureCount() throws {
    let link = FakeDDCLink(replies: [answering, [], [], answering, [], []])
    let (ddc, _) = backend(link)
    _ = ddc.probe(1)  // request 0: good

    _ = try ddc.level(for: 1)  // 1: miss
    _ = try ddc.level(for: 1)  // 2: miss
    _ = try ddc.level(for: 1)  // 3: good, resets
    _ = try ddc.level(for: 1)  // 4: miss
    _ = try ddc.level(for: 1)  // 5: miss
    let before = link.requestCount
    _ = try ddc.level(for: 1)  // 6: still allowed (only 3rd miss in the new run)

    #expect(link.requestCount == before + 1)
}

@Test func aReconfigurationLiftsTheWriteOnlyDowngradeAndForwardsTheNotice() throws {
    let link = FakeDDCLink(replies: [answering, []])
    let (ddc, links) = backend(link)
    _ = ddc.probe(1)
    for _ in 0..<DDCBackend.readFailureLimit { _ = try ddc.level(for: 1) }

    ddc.configurationDidChange()
    let before = link.requestCount
    _ = try ddc.level(for: 1)

    #expect(link.requestCount == before + 1)
    #expect(links.configurationChanges == 1)
}

@Test func readingADisplayWithNoLinkThrowsUnsupported() {
    let (ddc, _) = backend(nil)

    #expect(throws: DisplayError.brightnessUnsupported(1)) { try ddc.level(for: 1) }
}

@Test func theRouterPrefersDDCOverGammaWhenTheMonitorAnswers() throws {
    let (ddc, _) = backend(FakeDDCLink(replies: [answering]))
    let gamma = FakeBrightnessBackend(.gamma)
    let router = BrightnessRouter(backends: [ddc, gamma])

    #expect(router.route(for: 1) == BrightnessRoute(method: .ddc, readable: true))
}

@Test func theRouterFallsBackToGammaWhenTheMonitorIsSilent() {
    let (ddc, _) = backend(FakeDDCLink(replies: [[UInt8](repeating: 0xFA, count: 12)]))
    let gamma = FakeBrightnessBackend(.gamma)
    let router = BrightnessRouter(backends: [ddc, gamma])

    #expect(router.route(for: 1)?.method == .gamma)
}

@Test func aReconfigurationForgetsTheMaximumBecauseTheIDMayBeADifferentMonitor() throws {
    // Display IDs are reassigned on replug (spec §9). A write scaled by the old
    // monitor's range would be wrong on the new one.
    let link = FakeDDCLink(replies: [FakeDDCLink.luminanceReply(current: 10, maximum: 200)])
    let (ddc, _) = backend(link)
    _ = ddc.probe(1)

    ddc.configurationDidChange()
    link.replies = [FakeDDCLink.luminanceReply(current: 10, maximum: 100)]
    try ddc.setLevel(BrightnessLevel(0.5), for: 1)

    #expect(link.sent == [DDC.setVCP(DDC.luminance, value: 50)])
}
