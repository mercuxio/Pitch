import Testing

@testable import DisplayCore

// MARK: - BrightnessLevel and floors

@Test func aLevelIsClampedIntoZeroToOne() {
    #expect(BrightnessLevel(-3).value == 0)
    #expect(BrightnessLevel(7).value == 1)
    #expect(BrightnessLevel(0.4).value == 0.4)
}

@Test func garbageNeverBecomesARequestToGoDark() {
    #expect(BrightnessLevel(.nan).value == 1)
    #expect(BrightnessLevel(.infinity).value == 1)
    #expect(BrightnessLevel(-.infinity).value == 1)
}

@Test func softwareDimmingStopsEarlierThanABacklight() {
    // Gamma crushes toward black; the floor is what keeps the screen readable.
    #expect(BrightnessMethod.gamma.floor > BrightnessMethod.ddc.floor)
    #expect(BrightnessMethod.gamma.clamped(BrightnessLevel(0)).value == BrightnessMethod.gamma.floor)
    #expect(BrightnessMethod.ddc.clamped(BrightnessLevel(0)).value == BrightnessMethod.ddc.floor)
}

@Test func aFloorNeverRaisesALevelThatIsAlreadyHigher() {
    #expect(BrightnessMethod.gamma.clamped(BrightnessLevel(0.9)).value == 0.9)
}

// MARK: - Router

private func router(_ backends: FakeBrightnessBackend...) -> BrightnessRouter {
    BrightnessRouter(backends: backends)
}

@Test func theFirstSupportedBackendWins() {
    let apple = FakeBrightnessBackend(.appleDisplay)
    let ddc = FakeBrightnessBackend(.ddc)
    let gamma = FakeBrightnessBackend(.gamma)

    let route = router(apple, ddc, gamma).route(for: 1)

    #expect(route == BrightnessRoute(method: .appleDisplay, readable: true))
    #expect(ddc.probeCount == 0)
}

@Test func anUnsupportedBackendFallsThroughToTheNext() {
    let apple = FakeBrightnessBackend(.appleDisplay, probe: .unsupported)
    let ddc = FakeBrightnessBackend(.ddc, probe: .unsupported)
    let gamma = FakeBrightnessBackend(.gamma)

    #expect(router(apple, ddc, gamma).route(for: 1)?.method == .gamma)
}

@Test func aWriteOnlyDisplayIsRoutedButNotReadable() {
    let ddc = FakeBrightnessBackend(.ddc, probe: .supported(readable: false))

    #expect(router(ddc).route(for: 1) == BrightnessRoute(method: .ddc, readable: false))
}

@Test func nothingSupportedMeansNoRoute() {
    let r = router(FakeBrightnessBackend(.gamma, probe: .unsupported))

    #expect(r.route(for: 1) == nil)
    #expect(throws: DisplayError.brightnessUnsupported(1)) {
        try r.setLevel(BrightnessLevel(0.5), for: 1)
    }
}

@Test func theChoiceIsCachedUntilInvalidated() {
    let ddc = FakeBrightnessBackend(.ddc)
    let r = router(ddc)

    _ = r.route(for: 1)
    _ = r.route(for: 1)
    #expect(ddc.probeCount == 1)

    r.invalidate()
    _ = r.route(for: 1)
    #expect(ddc.probeCount == 2)
}

@Test func eachDisplayIsProbedOnItsOwn() {
    let ddc = FakeBrightnessBackend(.ddc)
    let r = router(ddc)

    _ = r.route(for: 1)
    _ = r.route(for: 2)

    #expect(ddc.probeCount == 2)
}

@Test func writesAreRaisedToTheFloorOfTheMechanismInUse() throws {
    let gamma = FakeBrightnessBackend(.gamma)
    let r = router(gamma)

    let applied = try r.setLevel(BrightnessLevel(0), for: 1)

    #expect(applied.value == BrightnessMethod.gamma.floor)
    #expect(gamma.writes.first?.level.value == BrightnessMethod.gamma.floor)
}

@Test func aWriteOnlyDisplayReportsNoLevelRatherThanAStaleOne() throws {
    let ddc = FakeBrightnessBackend(.ddc, probe: .supported(readable: false), level: BrightnessLevel(0.3))

    #expect(try router(ddc).level(for: 1) == nil)
}

@Test func aReadableDisplayReportsItsLiveLevel() throws {
    let apple = FakeBrightnessBackend(.appleDisplay, level: BrightnessLevel(0.7))

    #expect(try router(apple).level(for: 1) == BrightnessLevel(0.7))
}

@Test func aFailedWriteForgetsTheChoiceButDoesNotSwitchBackend() {
    let ddc = FakeBrightnessBackend(.ddc)
    let gamma = FakeBrightnessBackend(.gamma)
    let r = router(ddc, gamma)
    _ = r.route(for: 1)
    ddc.writeError = DisplayError.brightnessWriteFailed(1, code: -1)

    #expect(throws: DisplayError.brightnessWriteFailed(1, code: -1)) {
        try r.setLevel(BrightnessLevel(0.5), for: 1)
    }
    // Nothing was silently redirected to software dimming...
    #expect(gamma.writes.isEmpty)
    // ...and the next use probes again.
    _ = r.route(for: 1)
    #expect(ddc.probeCount == 2)
}

// MARK: - Router: trying again for a better mechanism

@Test func aDisplayThatFellToDimmingIsOfferedTheBetterBackendAgain() {
    // The monitor was not ready when it was first probed (just after wake), so
    // DDC said no and software dimming took the display.
    let ddc = FakeBrightnessBackend(.ddc, probe: .unsupported)
    let gamma = FakeBrightnessBackend(.gamma)
    let r = router(ddc, gamma)
    #expect(r.route(for: 1)?.method == .gamma)

    ddc.probeResult = .supported(readable: true)
    let upgraded = r.upgrade(1)

    #expect(upgraded == BrightnessRoute(method: .ddc, readable: true))
    #expect(r.route(for: 1)?.method == .ddc)
}

@Test func anUpgradeThatFindsNothingBetterLeavesTheRouteAlone() {
    let ddc = FakeBrightnessBackend(.ddc, probe: .unsupported)
    let gamma = FakeBrightnessBackend(.gamma)
    let r = router(ddc, gamma)
    _ = r.route(for: 1)

    #expect(r.upgrade(1) == nil)
    #expect(r.route(for: 1)?.method == .gamma)
    // The backend in use is not probed again: only the ones preferred over it.
    #expect(gamma.probeCount == 1)
    #expect(ddc.probeCount == 2)
}

@Test func aDisplayOnItsFirstChoiceIsNeverProbedAgain() {
    let apple = FakeBrightnessBackend(.appleDisplay)
    let r = router(apple, FakeBrightnessBackend(.gamma))
    _ = r.route(for: 1)

    #expect(r.upgrade(1) == nil)
    #expect(apple.probeCount == 1)
}

@Test func aDisplayWithNoRouteYetHasNothingToUpgrade() {
    let ddc = FakeBrightnessBackend(.ddc)

    #expect(router(ddc, FakeBrightnessBackend(.gamma)).upgrade(1) == nil)
    #expect(ddc.probeCount == 0)
}

@Test func anUpgradeMakesBackendsAboveTheCurrentOneDropStaleState() {
    // DDC caches which service belongs to which display; one built while the
    // monitor was still waking would otherwise be asked again unchanged.
    let ddc = FakeBrightnessBackend(.ddc, probe: .unsupported)
    let gamma = FakeBrightnessBackend(.gamma)
    let r = router(ddc, gamma)
    _ = r.route(for: 1)

    _ = r.upgrade(1)

    #expect(ddc.configurationChangeCount == 1)
    #expect(gamma.configurationChangeCount == 0)
}

@Test func aSuccessfulUpgradeReleasesTheDimmingItReplaced() {
    let ddc = FakeBrightnessBackend(.ddc, probe: .unsupported)
    let gamma = FakeBrightnessBackend(.gamma)
    let r = router(ddc, gamma)
    _ = r.route(for: 1)
    ddc.probeResult = .supported(readable: true)

    _ = r.upgrade(1)

    // Left alone, a dimmed gamma table would stay on the screen with no slider
    // that could undo it.
    #expect(gamma.configurationChangeCount == 1)
}

@Test func anUpgradeLosesToAnInvalidationThatRacedIt() {
    let ddc = FakeBrightnessBackend(.ddc, probe: .unsupported)
    let r = router(ddc, FakeBrightnessBackend(.gamma))
    _ = r.route(for: 1)
    r.invalidate()

    // The cache was cleared, so there is no route to improve on.
    #expect(r.upgrade(1) == nil)
}

// MARK: - Write throttle

@Test func theFirstWriteGoesOutImmediately() {
    var throttle = WriteThrottle(minimumInterval: 0.05)

    #expect(throttle.offer(BrightnessLevel(0.5), now: 10) == BrightnessLevel(0.5))
    #expect(throttle.pending == nil)
}

@Test func aDragKeepsOnlyTheLatestValue() {
    var throttle = WriteThrottle(minimumInterval: 0.05)
    _ = throttle.offer(BrightnessLevel(0.1), now: 10)

    #expect(throttle.offer(BrightnessLevel(0.2), now: 10.01) == nil)
    #expect(throttle.offer(BrightnessLevel(0.3), now: 10.02) == nil)
    #expect(throttle.offer(BrightnessLevel(0.4), now: 10.03) == nil)

    #expect(throttle.pending == BrightnessLevel(0.4))
    // Not yet due: nothing is released early, and nothing is queued behind it.
    #expect(throttle.takePending(now: 10.04) == nil)
    #expect(throttle.takePending(now: 10.06) == BrightnessLevel(0.4))
    #expect(throttle.takePending(now: 10.2) == nil)
}

@Test func theHeldValueReportsHowLongUntilItIsDue() {
    var throttle = WriteThrottle(minimumInterval: 0.05)
    #expect(throttle.secondsUntilPendingIsDue(now: 10) == nil)

    _ = throttle.offer(BrightnessLevel(0.1), now: 10)
    _ = throttle.offer(BrightnessLevel(0.2), now: 10.02)

    let wait = throttle.secondsUntilPendingIsDue(now: 10.02)
    #expect(wait != nil)
    #expect(abs((wait ?? -1) - 0.03) < 1e-9)
}

@Test func aValueOfferedAfterTheIntervalGoesStraightOut() {
    var throttle = WriteThrottle(minimumInterval: 0.05)
    _ = throttle.offer(BrightnessLevel(0.1), now: 10)

    #expect(throttle.offer(BrightnessLevel(0.9), now: 10.5) == BrightnessLevel(0.9))
}

// MARK: - DDC frames

@Test func aSetLuminanceFrameCarriesTheMCCSChecksum() {
    // 0x6E ^ 0x51 ^ 0x84 ^ 0x03 ^ 0x10 ^ 0x00 ^ 0x32 = 0x9A, worked by hand
    // from the layout rather than taken from the implementation.
    #expect(DDC.setVCP(DDC.luminance, value: 50) == [0x84, 0x03, 0x10, 0x00, 0x32, 0x9A])
}

@Test func aValueAboveOneByteSplitsHighThenLow() {
    let frame = DDC.setVCP(DDC.luminance, value: 0x0123)

    #expect(Array(frame[3...4]) == [0x01, 0x23])
}

@Test func aGetLuminanceFrameCarriesTheMCCSChecksum() {
    // 0x6E ^ 0x51 ^ 0x82 ^ 0x01 ^ 0x10 = 0xAC
    #expect(DDC.getVCP(DDC.luminance) == [0x82, 0x01, 0x10, 0xAC])
}

private let replyFor50of100: [UInt8] = [
    0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32, 0xF2,
]

@Test func aGetReplyYieldsTheLevelAsAFractionOfTheMonitorsOwnMaximum() throws {
    let reply = try DDC.parseReply(replyFor50of100, expecting: DDC.luminance)

    #expect(reply.current == 50)
    #expect(reply.maximum == 100)
    #expect(reply.checksumValid)
    #expect(reply.level == BrightnessLevel(0.5))
}

@Test func aReplyWhoseHeaderIsTheNullMessageStillCarriesItsPayload() throws {
    // Recorded from the LG on the development machine: `6E 80 BE` is the DDC/CI
    // null message, but the eight bytes after it are a complete luminance reply
    // and their checksum is only valid against the ordinary `88 02` header.
    let recorded: [UInt8] = [
        0x6E, 0x80, 0xBE, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32, 0xF2, 0x00,
    ]

    let reply = try DDC.parseReply(recorded, expecting: DDC.luminance)

    #expect(reply.current == 50)
    #expect(reply.maximum == 100)
    #expect(reply.checksumValid)
}

@Test func aNullMessageWithNothingBehindItIsNotAReply() {
    let empty: [UInt8] = [0x6E, 0x80, 0xBE, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]

    #expect(throws: DDC.FrameError.wrongFeature(0x00)) {
        try DDC.parseReply(empty, expecting: DDC.luminance)
    }
}

@Test func aMaximumOtherThanOneHundredIsHonoured() throws {
    // Max 255, current 128. The checksum is wrong on purpose here; the point is
    // the arithmetic, and `checksumValid` is asserted separately below.
    let bytes: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0xFF, 0x00, 0x80, 0x00]

    let reply = try DDC.parseReply(bytes, expecting: DDC.luminance)

    #expect(reply.maximum == 255)
    let level = try #require(reply.level)
    #expect(abs(level.value - 128.0 / 255.0) < 1e-9)
}

@Test func theReplyParsesWithOrWithoutItsLeadingSourceByte() throws {
    let withoutSource = Array(replyFor50of100.dropFirst())

    let reply = try DDC.parseReply(withoutSource, expecting: DDC.luminance)

    #expect(reply.current == 50)
    #expect(reply.checksumValid)
}

@Test func aBadChecksumIsReportedNotThrown() throws {
    var bytes = replyFor50of100
    bytes[10] ^= 0xFF

    let reply = try DDC.parseReply(bytes, expecting: DDC.luminance)

    #expect(!reply.checksumValid)
}

@Test func aMaximumOfZeroHasNoLevel() throws {
    let bytes: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]

    #expect(try DDC.parseReply(bytes, expecting: DDC.luminance).level == nil)
}

@Test func malformedRepliesAreRefusedRatherThanGuessedAt() {
    #expect(throws: DDC.FrameError.tooShort) {
        try DDC.parseReply([0x6E, 0x88, 0x02], expecting: DDC.luminance)
    }
    #expect(throws: DDC.FrameError.tooShort) {
        try DDC.parseReply([], expecting: DDC.luminance)
    }
    #expect(throws: DDC.FrameError.notAGetReply) {
        try DDC.parseReply([0x6E, 0x88, 0x09, 0x00, 0x10, 0, 0, 0x64, 0, 0x32, 0], expecting: DDC.luminance)
    }
    #expect(throws: DDC.FrameError.unsupportedFeature) {
        try DDC.parseReply([0x6E, 0x88, 0x02, 0x01, 0x10, 0, 0, 0x64, 0, 0x32, 0], expecting: DDC.luminance)
    }
    #expect(throws: DDC.FrameError.wrongFeature(0x12)) {
        try DDC.parseReply([0x6E, 0x88, 0x02, 0x00, 0x12, 0, 0, 0x64, 0, 0x32, 0], expecting: DDC.luminance)
    }
}

@Test func rawValuesScaleToTheReportedMaximum() {
    #expect(DDC.rawValue(for: BrightnessLevel(0.5), maximum: 100) == 50)
    #expect(DDC.rawValue(for: BrightnessLevel(1), maximum: 255) == 255)
    #expect(DDC.rawValue(for: BrightnessLevel(0.5), maximum: 255) == 128)
    #expect(DDC.rawValue(for: BrightnessLevel(0), maximum: 100) == 0)
}
