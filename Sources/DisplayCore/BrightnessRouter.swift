import CoreGraphics
import Foundation

/// The backend chosen for one display, and whether its level can be read back.
public struct BrightnessRoute: Equatable, Sendable {
    public let method: BrightnessMethod
    public let readable: Bool

    public init(method: BrightnessMethod, readable: Bool) {
        self.method = method
        self.readable = readable
    }
}

/// Picks a backend per display and remembers the answer (spec §18.2).
///
/// The cache is keyed by `CGDirectDisplayID` and is meant to be thrown away:
/// the ID is reassigned on replug (spec §9), so an entry that outlives a display
/// reconfiguration may describe a different monitor. The caller invalidates on
/// every reconfiguration and on wake; nothing here does it on a timer.
public final class BrightnessRouter: @unchecked Sendable {
    private struct Entry {
        let backend: any BrightnessBackend
        let route: BrightnessRoute
        /// Position in the preference order; 0 is the most preferred.
        let rank: Int
    }

    private let backends: [any BrightnessBackend]
    private let lock = NSLock()
    private var cache: [CGDirectDisplayID: Entry] = [:]

    /// `backends` in preference order: the first whose probe is not
    /// `.unsupported` wins.
    public init(backends: [any BrightnessBackend]) {
        self.backends = backends
    }

    /// Which mechanism drives `id`, or `nil` if none can.
    public func route(for id: CGDirectDisplayID) -> BrightnessRoute? {
        entry(for: id)?.route
    }

    /// Forgets every cached choice and tells each backend the configuration
    /// changed, so none of them keeps state for an ID that may now be a
    /// different monitor.
    public func invalidate() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
        for backend in backends { backend.configurationDidChange() }
    }

    /// Asks again whether a mechanism preferred over the one in use will now
    /// drive `id`, and switches to it if so. Returns the new route, or `nil`
    /// when nothing changed.
    ///
    /// A monitor that has just woken often does not answer DDC for a while, so
    /// the first probe after wake can lose to software dimming, and that
    /// answer is cached until the next reconfiguration. The caller retries
    /// here for a short while after wake instead of leaving the slider on
    /// dimming for good.
    ///
    /// Only the backends above the current one are touched. Each is told the
    /// configuration changed first, so DDC drops the service map it built
    /// while the monitor was still waking; the backend being replaced is told
    /// the same once the switch is made, which lets software dimming put the
    /// screen back rather than leave a dimmed table nothing can undo.
    public func upgrade(_ id: CGDirectDisplayID) -> BrightnessRoute? {
        lock.lock()
        let current = cache[id]
        lock.unlock()
        guard let current, current.rank > 0 else { return nil }

        let better = backends[..<current.rank]
        for backend in better { backend.configurationDidChange() }

        for (rank, backend) in better.enumerated() {
            guard let found = probed(backend, rank: rank, for: id) else { continue }
            lock.lock()
            // An invalidation, or another upgrade, may have landed while this
            // probed; only replace the entry this started from.
            let stillCurrent = cache[id]?.rank == current.rank
            if stillCurrent { cache[id] = found }
            lock.unlock()
            guard stillCurrent else { return nil }
            current.backend.configurationDidChange()
            return found.route
        }
        return nil
    }

    /// Tells every backend the process is ending, so software dimming does not
    /// have to be trusted to clean up after itself (spec §18.5).
    public func shutDown() {
        for backend in backends { backend.shutDown() }
    }

    /// The live level; `nil` for a write-only display.
    public func level(for id: CGDirectDisplayID) throws -> BrightnessLevel? {
        guard let entry = entry(for: id) else { throw DisplayError.brightnessUnsupported(id) }
        guard entry.route.readable else { return nil }
        return try entry.backend.level(for: id)
    }

    /// Writes `level`, raised to the floor of the mechanism in use.
    ///
    /// A failed write drops the cached choice so the next attempt probes again
    /// instead of retrying a backend that has stopped working (a cable swapped,
    /// a dock reset). It does not fall through to another backend on its own:
    /// silently switching from a monitor's backlight to software dimming would
    /// change what the slider means underneath the user.
    @discardableResult
    public func setLevel(_ level: BrightnessLevel, for id: CGDirectDisplayID) throws
        -> BrightnessLevel
    {
        guard let entry = entry(for: id) else { throw DisplayError.brightnessUnsupported(id) }
        let applied = entry.route.method.clamped(level)
        do {
            try entry.backend.setLevel(applied, for: id)
        } catch {
            forget(id)
            throw error
        }
        return applied
    }

    private func entry(for id: CGDirectDisplayID) -> Entry? {
        lock.lock()
        if let hit = cache[id] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        // Probe outside the lock: a probe may touch IOKit and take real time.
        for (rank, backend) in backends.enumerated() {
            guard let found = probed(backend, rank: rank, for: id) else { continue }
            lock.lock()
            defer { lock.unlock() }
            // Another caller may have probed the same display meanwhile; keep
            // whichever landed first so the route never flips under a reader.
            if let raced = cache[id] { return raced }
            cache[id] = found
            return found
        }
        return nil
    }

    private func probed(_ backend: any BrightnessBackend, rank: Int, for id: CGDirectDisplayID)
        -> Entry?
    {
        guard case .supported(let readable) = backend.probe(id) else { return nil }
        return Entry(
            backend: backend,
            route: BrightnessRoute(method: backend.method, readable: readable),
            rank: rank)
    }

    private func forget(_ id: CGDirectDisplayID) {
        lock.lock()
        defer { lock.unlock() }
        cache[id] = nil
    }
}
