/// Latest-wins pacing for slow brightness writes (spec §18.4).
///
/// A DDC write takes tens of milliseconds, and a slider drag produces them far
/// faster than that. Queueing every value would leave the monitor chasing the
/// thumb for seconds after the user lets go, so only the most recent value is
/// kept. A pure value type: time arrives as an argument from the injected
/// `MonotonicClock`, so the pacing is testable without waiting.
public struct WriteThrottle: Sendable {
    public let minimumInterval: Double
    private var lastSent: Double?
    public private(set) var pending: BrightnessLevel?

    public init(minimumInterval: Double) {
        self.minimumInterval = minimumInterval
    }

    /// A new value from the slider. Returns it if it may be sent now; otherwise
    /// holds it as `pending`, replacing whatever was held.
    public mutating func offer(_ level: BrightnessLevel, now: Double) -> BrightnessLevel? {
        if isReady(now: now) {
            lastSent = now
            pending = nil
            return level
        }
        pending = level
        return nil
    }

    /// The held value, if enough time has passed to send it.
    public mutating func takePending(now: Double) -> BrightnessLevel? {
        guard let held = pending, isReady(now: now) else { return nil }
        lastSent = now
        pending = nil
        return held
    }

    /// How long until a held value may go out; `nil` when nothing is held.
    public func secondsUntilPendingIsDue(now: Double) -> Double? {
        guard pending != nil, let lastSent else { return pending == nil ? nil : 0 }
        return max(0, lastSent + minimumInterval - now)
    }

    private func isReady(now: Double) -> Bool {
        guard let lastSent else { return true }
        return now - lastSent >= minimumInterval
    }
}
