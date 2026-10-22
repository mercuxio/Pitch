import AppKit
import CoreGraphics
import DisplayCore

/// Owns everything brightness in the app: which mechanism drives each display,
/// what its slider shows, and getting a dragged value to the hardware (spec §18).
///
/// Main-actor confined, like the menu controller that hosts it. The only work
/// that leaves the main thread is the slow part — probing a backend and reading
/// a level, which may mean I²C traffic — and each result comes back tagged with
/// the generation it started in, so an answer that arrives after a replug or a
/// wake is dropped rather than attached to a display ID that now names a
/// different monitor.
///
/// Nothing here reapplies a stored level at launch or wake (spec §18.3): the
/// slider reflects the display, and only a drag changes it.
@MainActor
final class BrightnessController {
    private struct Resolved {
        let route: BrightnessRoute
        /// What the slider shows. Starts as the live reading and then follows
        /// the user's drags, so rebuilding the panel does not snap it back.
        var level: BrightnessLevel?
        /// The display cannot be read back, so the last value Pitch set is the
        /// only record there is (spec §18.3) and is the one thing worth saving.
        let writeOnly: Bool
    }

    private let router: BrightnessRouter
    private let recents: RecentsBook
    private let displayIDs: () -> [CGDirectDisplayID]
    private let resolveQueue = DispatchQueue(
        label: "com.houlanyit.Pitch.brightness.resolve", qos: .userInitiated)

    private lazy var writer = BrightnessWriter(
        router: router, clock: SystemClock(),
        onFailure: { [weak self] id, error in
            Task { @MainActor in self?.writeFailed(id, error) }
        })

    private var resolved: [CGDirectDisplayID: Resolved] = [:]
    /// Displays no backend can drive. Remembered so that opening the panel does
    /// not probe them again: probing a monitor that ignores DDC is not free.
    private var undrivable: Set<CGDirectDisplayID> = []
    private var failures: [CGDirectDisplayID: Error] = [:]

    private var generation = 0
    /// How long after landing on software dimming to ask again for a better
    /// mechanism. A monitor that has just woken can take tens of seconds to
    /// answer DDC, and the first probe after wake is made half a second in.
    private static let upgradeDelays: [TimeInterval] = [2, 5, 10, 20, 40]
    private var rewarm: DispatchWorkItem?
    /// A drag is under way. A rebuild now would replace the slider the user is
    /// holding.
    private var isInteracting = false

    /// Something a visible row depends on changed.
    var onChange: () -> Void = {}

    init(
        router: BrightnessRouter = .system(),
        recents: RecentsBook,
        displayIDs: @escaping () -> [CGDirectDisplayID]
    ) {
        self.router = router
        self.recents = recents
        self.displayIDs = displayIDs

        // Registered for the life of the process: this controller is never
        // released, so there is nothing to unregister.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.configurationChanged() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.configurationChanged() }
        }
    }

    // MARK: - What the panel shows

    /// The slider row for `id`, or `nil` when none is known yet or no backend
    /// can drive it. Never probes: the panel is built on the main thread.
    func rowView(for id: CGDirectDisplayID) -> NSView? {
        guard let state = resolved[id] else { return nil }
        let model = BrightnessRowModel(
            route: state.route, level: state.level,
            remembered: state.writeOnly ? recents.brightness(for: id) : nil,
            failure: failures[id])
        return BrightnessRowView(model: model) { [weak self] value, phase in
            self?.userMoved(to: value, phase: phase, on: id)
        }
    }

    // MARK: - Resolving

    /// Work out how to drive each of `ids`, in the background. Called at launch
    /// so the first time the panel opens there is already something to show.
    func warmUp(_ ids: [CGDirectDisplayID]) {
        resolve(ids.filter { resolved[$0] == nil && !undrivable.contains($0) }, invalidating: false)
    }

    /// The panel opened on `id`: its level may have changed since (the keyboard
    /// brightness keys do not go through Pitch). Reads it again, and gives a
    /// display that failed another chance.
    func panelDidOpen(on id: CGDirectDisplayID) {
        failures[id] = nil
        if resolved[id] == nil, !undrivable.contains(id) {
            resolve([id], invalidating: false)
        } else if let state = resolved[id], state.route.readable {
            resolve([id], invalidating: false)
        }
        if resolved[id]?.route.method == .gamma { upgrade(id, thenRetryAs: nil) }
    }

    private func resolve(_ ids: [CGDirectDisplayID], invalidating: Bool) {
        guard !ids.isEmpty || invalidating else { return }
        let router = router
        let started = generation

        resolveQueue.async { [weak self] in
            if invalidating { router.invalidate() }

            var found: [CGDirectDisplayID: Resolved] = [:]
            var none: Set<CGDirectDisplayID> = []
            for id in ids {
                guard let route = router.route(for: id) else {
                    none.insert(id)
                    continue
                }
                let live = (try? router.level(for: id)) ?? nil
                found[id] = Resolved(
                    route: route, level: live, writeOnly: !route.readable || live == nil)
            }

            Task { @MainActor in
                self?.finishResolving(found, none: none, generation: started)
            }
        }
    }

    private func finishResolving(
        _ found: [CGDirectDisplayID: Resolved], none: Set<CGDirectDisplayID>, generation: Int
    ) {
        guard generation == self.generation else { return }

        var changed = false
        var newlyDimmed: [CGDirectDisplayID] = []
        for (id, state) in found {
            if state.route.method == .gamma, resolved[id]?.route.method != .gamma {
                newlyDimmed.append(id)
            }
            var state = state
            // A refresh that could not read the level must not erase what the
            // user last set on this display.
            if state.level == nil, let kept = resolved[id]?.level { state.level = kept }
            if resolved[id]?.route != state.route || resolved[id]?.level != state.level {
                changed = true
            }
            resolved[id] = state
            undrivable.remove(id)
        }
        for id in none where !undrivable.contains(id) {
            undrivable.insert(id)
            if resolved.removeValue(forKey: id) != nil { changed = true }
        }

        if changed, !isInteracting { onChange() }
        for id in newlyDimmed { scheduleUpgrade(of: id, attempt: 0) }
    }

    /// A display that fell to software dimming may only have lost its first
    /// probe because the monitor was still waking, and the router would keep
    /// that answer until the next reconfiguration. Asks again a few times,
    /// further apart each time, and then stops: a monitor that never answers
    /// is not worth probing for ever.
    private func scheduleUpgrade(of id: CGDirectDisplayID, attempt: Int) {
        guard attempt < Self.upgradeDelays.count else { return }
        let started = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.upgradeDelays[attempt]) {
            [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == started,
                    self.resolved[id]?.route.method == .gamma
                else { return }
                // A drag is under way: a new route now would replace the
                // slider being held. Try again on the next beat.
                if self.isInteracting {
                    self.scheduleUpgrade(of: id, attempt: attempt + 1)
                } else {
                    self.upgrade(id, thenRetryAs: attempt + 1)
                }
            }
        }
    }

    /// Off the main thread, like every probe. `next` is the attempt to schedule
    /// if nothing better answered; `nil` for a one-off try.
    private func upgrade(_ id: CGDirectDisplayID, thenRetryAs next: Int?) {
        let router = router
        let started = generation

        resolveQueue.async { [weak self] in
            guard let route = router.upgrade(id) else {
                Task { @MainActor in
                    guard let self, self.generation == started, let next else { return }
                    self.scheduleUpgrade(of: id, attempt: next)
                }
                return
            }
            let live = (try? router.level(for: id)) ?? nil
            let state = Resolved(
                route: route, level: live, writeOnly: !route.readable || live == nil)
            Task { @MainActor in
                self?.finishResolving([id: state], none: [], generation: started)
            }
        }
    }

    /// A display was attached, removed, resized or woken. Everything cached may
    /// describe a monitor that is no longer behind that ID.
    private func configurationChanged() {
        // Settling takes several notifications; acting on the first would probe
        // a configuration that is about to change again.
        rewarm?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.reset() }
        }
        rewarm = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func reset() {
        generation += 1
        resolved.removeAll()
        undrivable.removeAll()
        failures.removeAll()
        isInteracting = false
        resolve(displayIDs(), invalidating: true)
        onChange()
    }

    // MARK: - Writing

    private func userMoved(to value: Double, phase: BrightnessRowView.Phase, on id: CGDirectDisplayID) {
        guard var state = resolved[id] else { return }
        isInteracting = phase == .dragging

        let level = state.route.method.clamped(BrightnessLevel(value))
        state.level = level
        resolved[id] = state
        writer.set(level, for: id)

        if phase == .committed, state.writeOnly {
            recents.recordBrightness(level.value, for: id)
        }
    }

    private func writeFailed(_ id: CGDirectDisplayID, _ error: Error) {
        failures[id] = error
        isInteracting = false
        onChange()
    }

    /// Pitch is quitting (spec §18.5).
    func shutDown() {
        rewarm?.cancel()
        router.shutDown()
    }
}
