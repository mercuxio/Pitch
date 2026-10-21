import CoreGraphics
import Foundation

/// Somewhere to run a display's brightness work, serially and off the main
/// thread. A seam so the pacing below can be driven by hand in tests instead of
/// by sleeping.
public protocol BrightnessExecutor: Sendable {
    func run(_ work: @escaping @Sendable () -> Void)
    func run(afterSeconds delay: Double, _ work: @escaping @Sendable () -> Void)
}

/// One serial dispatch queue.
public struct DispatchBrightnessExecutor: BrightnessExecutor {
    private let queue: DispatchQueue

    public init(label: String) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    public func run(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }

    public func run(afterSeconds delay: Double, _ work: @escaping @Sendable () -> Void) {
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

/// Sends slider values to the router: one serial executor per display, the
/// latest value wins, and nothing runs on the caller's thread (spec §18.4).
///
/// Per display, so one slow DDC monitor cannot hold up the dimming of another.
///
/// Two mechanisms, deliberately separate:
/// - `set` overwrites a single `latest` slot, and every queued drain consumes
///   it. A burst of drags behind a slow write therefore collapses into one
///   write of the final value rather than a backlog the monitor chases.
/// - `WriteThrottle` spaces the writes that do go out, and holds the newest
///   value back until it is due. It is only ever touched on its display's
///   executor, so it needs no lock.
public final class BrightnessWriter: @unchecked Sendable {
    private final class Channel: @unchecked Sendable {
        let executor: any BrightnessExecutor
        let lock = NSLock()
        /// The newest value not yet consumed by a drain.
        var latest: BrightnessLevel?
        // The two below are touched only on `executor`.
        var throttle: WriteThrottle
        var timerArmed = false

        init(executor: any BrightnessExecutor, throttle: WriteThrottle) {
            self.executor = executor
            self.throttle = throttle
        }
    }

    private let router: BrightnessRouter
    private let clock: any MonotonicClock
    private let minimumInterval: Double
    private let makeExecutor: @Sendable (CGDirectDisplayID) -> any BrightnessExecutor
    private let onFailure: @Sendable (CGDirectDisplayID, Error) -> Void

    private let lock = NSLock()
    private var channels: [CGDirectDisplayID: Channel] = [:]

    /// - Parameter onFailure: called on the display's executor when a write
    ///   throws. The router has already dropped its cached choice by then.
    public init(
        router: BrightnessRouter,
        clock: any MonotonicClock,
        minimumInterval: Double = 0.05,
        makeExecutor: @escaping @Sendable (CGDirectDisplayID) -> any BrightnessExecutor = {
            DispatchBrightnessExecutor(label: "com.houlanyit.Pitch.brightness.\($0)")
        },
        onFailure: @escaping @Sendable (CGDirectDisplayID, Error) -> Void
    ) {
        self.router = router
        self.clock = clock
        self.minimumInterval = minimumInterval
        self.makeExecutor = makeExecutor
        self.onFailure = onFailure
    }

    /// Queue `level` for `id`. Returns immediately.
    public func set(_ level: BrightnessLevel, for id: CGDirectDisplayID) {
        let channel = channel(for: id)
        channel.lock.lock()
        channel.latest = level
        channel.lock.unlock()
        channel.executor.run { [self] in drain(channel, id) }
    }

    private func channel(for id: CGDirectDisplayID) -> Channel {
        lock.lock()
        defer { lock.unlock() }
        if let existing = channels[id] { return existing }
        let made = Channel(
            executor: makeExecutor(id), throttle: WriteThrottle(minimumInterval: minimumInterval))
        channels[id] = made
        return made
    }

    /// Runs on the channel's executor.
    private func drain(_ channel: Channel, _ id: CGDirectDisplayID) {
        channel.lock.lock()
        let wanted = channel.latest
        channel.latest = nil
        channel.lock.unlock()

        let due: BrightnessLevel?
        if let wanted {
            due = channel.throttle.offer(wanted, now: clock.nowSeconds)
        } else {
            // A drain with nothing new is either one whose value an earlier
            // drain already took, or the timer firing for a held value.
            due = channel.throttle.takePending(now: clock.nowSeconds)
        }

        if let due {
            do {
                try router.setLevel(due, for: id)
            } catch {
                onFailure(id, error)
            }
        }

        // Read again: the write above may have taken longer than the interval.
        guard !channel.timerArmed,
            let wait = channel.throttle.secondsUntilPendingIsDue(now: clock.nowSeconds)
        else { return }
        channel.timerArmed = true
        channel.executor.run(afterSeconds: wait) { [self] in
            channel.timerArmed = false
            drain(channel, id)
        }
    }
}
