import CoreGraphics
import Testing

@testable import DisplayCore

@Test func aDrivableDisplayIsSupportedAndAnInactiveOneIsNot() {
    let tables = FakeGammaTables()
    let backend = GammaBackend(tables: tables)

    #expect(backend.probe(1) == .supported(readable: true))
    #expect(backend.probe(2) == .unsupported)
}

@Test func probingNeverWritesOrCaptures() {
    let tables = FakeGammaTables()

    _ = GammaBackend(tables: tables).probe(1)

    #expect(tables.applications.isEmpty)
    #expect(tables.captureCount == 0)
}

@Test func dimmingScalesEveryChannelOfTheBaseline() throws {
    let tables = FakeGammaTables()
    let backend = GammaBackend(tables: tables)

    try backend.setLevel(BrightnessLevel(0.5), for: 1)

    let applied = try #require(tables.applications.last?.table)
    #expect(applied == GammaTable(red: [0, 0.25, 0.5], green: [0, 0.25, 0.5], blue: [0, 0.25, 0.5]))
}

@Test func theBaselineIsCapturedOnceNotOnEveryChange() throws {
    // Capturing again while Pitch's own dimmed table is live would take the
    // dimmed table as normal and dim it twice.
    let tables = FakeGammaTables()
    let backend = GammaBackend(tables: tables)

    try backend.setLevel(BrightnessLevel(0.5), for: 1)
    try backend.setLevel(BrightnessLevel(0.5), for: 1)
    try backend.setLevel(BrightnessLevel(0.5), for: 1)

    #expect(tables.captureCount == 1)
    let last = try #require(tables.applications.last?.table)
    #expect(last.red.last == 0.5)
}

@Test func eachDisplayKeepsItsOwnBaselineAndLevel() throws {
    let tables = FakeGammaTables()
    tables.drivable = [1, 2]
    let backend = GammaBackend(tables: tables)

    try backend.setLevel(BrightnessLevel(0.5), for: 1)
    try backend.setLevel(BrightnessLevel(0.8), for: 2)

    #expect(try backend.level(for: 1) == BrightnessLevel(0.5))
    #expect(try backend.level(for: 2) == BrightnessLevel(0.8))
    #expect(tables.captureCount == 2)
}

@Test func anUntouchedDisplayReadsAsFull() throws {
    #expect(try GammaBackend(tables: FakeGammaTables()).level(for: 1) == BrightnessLevel.full)
}

@Test func aRefusedWriteThrowsAndIsNotRecorded() {
    let tables = FakeGammaTables()
    tables.applyCode = 1001
    let backend = GammaBackend(tables: tables)

    #expect(throws: DisplayError.brightnessWriteFailed(1, code: 1001)) {
        try backend.setLevel(BrightnessLevel(0.5), for: 1)
    }
    #expect((try? backend.level(for: 1)) == BrightnessLevel.full)
}

@Test func aDisplayWithNoReadableTableIsUnsupportedRatherThanDimmedBlind() {
    final class NoCapture: GammaTables, @unchecked Sendable {
        func canDrive(_ id: CGDirectDisplayID) -> Bool { true }
        func capture(_ id: CGDirectDisplayID) -> GammaTable? { nil }
        func apply(_ table: GammaTable, to id: CGDirectDisplayID) -> Int32 { 0 }
        func restoreSystemSettings() {}
    }

    #expect(throws: DisplayError.brightnessUnsupported(1)) {
        try GammaBackend(tables: NoCapture()).setLevel(BrightnessLevel(0.5), for: 1)
    }
}

@Test func restoringHandsTheScreenBackToTheSystemAndForgetsTheLevel() throws {
    let tables = FakeGammaTables()
    let backend = GammaBackend(tables: tables)
    try backend.setLevel(BrightnessLevel(0.5), for: 1)

    backend.restoreAll()

    #expect(tables.restoreCount == 1)
    #expect(try backend.level(for: 1) == BrightnessLevel.full)
    // And the next dim captures afresh, from the restored state.
    try backend.setLevel(BrightnessLevel(0.5), for: 1)
    #expect(tables.captureCount == 2)
}

@Test func aReconfigurationResetsDimmingInsteadOfCarryingItAcross() throws {
    let tables = FakeGammaTables()
    let backend = GammaBackend(tables: tables)
    try backend.setLevel(BrightnessLevel(0.5), for: 1)

    backend.configurationDidChange()

    #expect(tables.restoreCount == 1)
    #expect(try backend.level(for: 1) == BrightnessLevel.full)
}

@Test func aReconfigurationLeavesAnUntouchedSystemAlone() {
    // If Pitch never dimmed anything, restoring would undo someone else's
    // colour adjustment for no reason.
    let tables = FakeGammaTables()

    GammaBackend(tables: tables).configurationDidChange()

    #expect(tables.restoreCount == 0)
}

@Test func theRouterTellsEveryBackendWhenTheConfigurationChanges() throws {
    let tables = FakeGammaTables()
    let gamma = GammaBackend(tables: tables)
    let router = BrightnessRouter(backends: [gamma])
    try router.setLevel(BrightnessLevel(0.5), for: 1)

    router.invalidate()

    #expect(tables.restoreCount == 1)
}
