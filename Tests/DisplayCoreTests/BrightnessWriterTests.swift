import CoreGraphics
import Foundation
import Testing

@testable import DisplayCore

private final class Failures: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [CGDirectDisplayID] = []

    func record(_ id: CGDirectDisplayID) {
        lock.lock()
        recorded.append(id)
        lock.unlock()
    }

    var ids: [CGDirectDisplayID] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

// Intervals are binary fractions on purpose: 100.1 - 100 is just under 0.1.
private struct Harness {
    let backend = FakeBrightnessBackend(.ddc)
    let executor = ManualExecutor()
    let clock = FakeClock(startingAt: 100)
    let failures = Failures()
    let writer: BrightnessWriter

    init(interval: Double = 0.25) {
        let router = BrightnessRouter(backends: [backend])
        let executor = executor
        let failures = failures
        writer = BrightnessWriter(
            router: router, clock: clock, minimumInterval: interval,
            makeExecutor: { _ in executor },
            onFailure: { id, _ in failures.record(id) })
    }

    var written: [Double] { backend.writes.map(\.level.value) }
}

@Test func settingReturnsImmediatelyAndWritesOnTheExecutor() {
    let h = Harness()

    h.writer.set(BrightnessLevel(0.6), for: 1)

    #expect(h.written.isEmpty)
    h.executor.runPending()
    #expect(h.written == [0.6])
}

@Test func valuesQueuedBehindASlowExecutorCollapseToTheNewestOne() {
    // The executor is busy (a slow DDC write): four values arrive before it
    // gets round to any of them. Only the last is worth sending.
    let h = Harness()
    h.writer.set(BrightnessLevel(0.9), for: 1)
    h.writer.set(BrightnessLevel(0.8), for: 1)
    h.writer.set(BrightnessLevel(0.7), for: 1)
    h.writer.set(BrightnessLevel(0.4), for: 1)

    h.executor.runPending()

    #expect(h.written == [0.4])
}

@Test func aDragFasterThanTheIntervalSendsTheFirstThenOnlyTheNewestHeld() {
    let h = Harness()
    for value in [0.9, 0.8, 0.7, 0.4] {
        h.writer.set(BrightnessLevel(value), for: 1)
        h.executor.runPending()
    }

    // The first goes straight out; the rest were held, and only 0.4 survives.
    #expect(h.written == [0.9])

    h.clock.advance(by: 0.25)
    h.executor.runPending()
    #expect(h.written == [0.9, 0.4])
}

@Test func theFinalValueIsAlwaysWrittenEvenAfterTheDragStops() {
    let h = Harness()
    h.writer.set(BrightnessLevel(0.9), for: 1)
    h.executor.runPending()
    h.writer.set(BrightnessLevel(0.5), for: 1)
    h.executor.runPending()

    // Nobody touches the slider again: the timer alone must deliver 0.5.
    h.clock.advance(by: 0.25)
    h.executor.runPending()

    #expect(h.written.last == 0.5)
}

@Test func aHeldValueWaitsForTheIntervalRatherThanBeingSentEarly() {
    let h = Harness(interval: 0.25)
    h.writer.set(BrightnessLevel(0.9), for: 1)
    h.executor.runPending()
    h.writer.set(BrightnessLevel(0.5), for: 1)
    h.executor.runPending()

    h.clock.advance(by: 0.125)
    h.executor.runPending()

    #expect(h.written == [0.9])
    #expect(h.executor.pendingCount == 1)
}

@Test func onlyOneTimerIsOutstandingHoweverManyValuesArrive() {
    let h = Harness()
    h.writer.set(BrightnessLevel(0.9), for: 1)
    h.executor.runPending()
    for step in 1...20 {
        h.writer.set(BrightnessLevel(0.9 - Double(step) * 0.02), for: 1)
        h.executor.runPending()
    }

    // However many values arrived, exactly one timer is waiting.
    #expect(h.executor.pendingCount == 1)
}

@Test func aFailedWriteIsReportedAgainstItsDisplay() {
    let h = Harness()
    h.backend.writeError = DisplayError.brightnessWriteFailed(7, code: 5)

    h.writer.set(BrightnessLevel(0.5), for: 7)
    h.executor.runPending()

    #expect(h.failures.ids == [7])
}

@Test func eachDisplayIsPacedOnItsOwn() {
    let h = Harness()

    h.writer.set(BrightnessLevel(0.5), for: 1)
    h.writer.set(BrightnessLevel(0.6), for: 2)
    h.executor.runPending()

    // Display 2's first write is not held back by display 1's.
    #expect(h.backend.writes.map(\.id) == [1, 2])
    #expect(h.written == [0.5, 0.6])
}

@Test func eachDisplayGetsItsOwnExecutor() {
    final class Made: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [CGDirectDisplayID] = []
        func note(_ id: CGDirectDisplayID) {
            lock.lock()
            ids.append(id)
            lock.unlock()
        }
        var all: [CGDirectDisplayID] {
            lock.lock()
            defer { lock.unlock() }
            return ids
        }
    }
    let made = Made()
    let writer = BrightnessWriter(
        router: BrightnessRouter(backends: [FakeBrightnessBackend(.ddc)]),
        clock: FakeClock(),
        makeExecutor: { id in
            made.note(id)
            return ManualExecutor()
        },
        onFailure: { _, _ in })

    writer.set(BrightnessLevel(0.5), for: 1)
    writer.set(BrightnessLevel(0.5), for: 1)
    writer.set(BrightnessLevel(0.5), for: 2)

    #expect(made.all == [1, 2])
}
