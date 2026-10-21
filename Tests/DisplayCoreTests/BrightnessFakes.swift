import CoreGraphics
import Foundation

@testable import DisplayCore

/// A scripted `BrightnessBackend`. Never touches a display.
final class FakeBrightnessBackend: BrightnessBackend, @unchecked Sendable {
    let method: BrightnessMethod
    var probeResult: BrightnessProbe
    var storedLevel: BrightnessLevel?
    var writeError: Error?

    private(set) var probeCount = 0
    private(set) var shutDownCount = 0
    private(set) var writes: [(level: BrightnessLevel, id: CGDirectDisplayID)] = []

    init(
        _ method: BrightnessMethod,
        probe: BrightnessProbe = .supported(readable: true),
        level: BrightnessLevel? = nil
    ) {
        self.method = method
        self.probeResult = probe
        self.storedLevel = level
    }

    func probe(_ id: CGDirectDisplayID) -> BrightnessProbe {
        probeCount += 1
        return probeResult
    }

    func level(for id: CGDirectDisplayID) throws -> BrightnessLevel? { storedLevel }

    func setLevel(_ level: BrightnessLevel, for id: CGDirectDisplayID) throws {
        if let writeError { throw writeError }
        writes.append((level, id))
        storedLevel = level
    }

    func shutDown() { shutDownCount += 1 }
}

/// Gamma tables held in memory. Never touches a display.
final class FakeGammaTables: GammaTables, @unchecked Sendable {
    var drivable: Set<CGDirectDisplayID> = [1]
    var system = GammaTable(red: [0, 0.5, 1], green: [0, 0.5, 1], blue: [0, 0.5, 1])
    var applyCode: Int32 = 0

    private(set) var captureCount = 0
    private(set) var applications: [(id: CGDirectDisplayID, table: GammaTable)] = []
    private(set) var restoreCount = 0
    /// What a real display would currently be showing.
    private(set) var live: [CGDirectDisplayID: GammaTable] = [:]

    func canDrive(_ id: CGDirectDisplayID) -> Bool { drivable.contains(id) }

    func capture(_ id: CGDirectDisplayID) -> GammaTable? {
        captureCount += 1
        return live[id] ?? system
    }

    func apply(_ table: GammaTable, to id: CGDirectDisplayID) -> Int32 {
        applications.append((id, table))
        if applyCode == 0 { live[id] = table }
        return applyCode
    }

    func restoreSystemSettings() {
        restoreCount += 1
        live.removeAll()
    }
}

/// DisplayServices calls scripted per display. Never touches a panel.
final class FakeDisplayServices: DisplayServicesCalls, @unchecked Sendable {
    var isAvailable = true
    var panels: [CGDirectDisplayID: Float] = [1: 0.5]
    var getStatus: Int32 = 0
    var setStatus: Int32 = 0

    private(set) var sets: [(id: CGDirectDisplayID, value: Float)] = []

    func get(_ id: CGDirectDisplayID) -> (status: Int32, value: Float) {
        guard let value = panels[id] else { return (-1, 0) }
        return (getStatus, value)
    }

    func set(_ id: CGDirectDisplayID, _ value: Float) -> Int32 {
        sets.append((id, value))
        if setStatus == 0 { panels[id] = value }
        return setStatus
    }
}

/// A monitor's DDC bus, scripted. Never touches a display.
///
/// `replies` are consumed one per request, the last repeating, so a test can say
/// "silent, then answers" without a clock.
final class FakeDDCLink: DDCLink, @unchecked Sendable {
    var replies: [[UInt8]]
    var requestStatus: Int32 = 0
    var sendStatus: Int32 = 0

    private(set) var requestCount = 0
    private(set) var sent: [[UInt8]] = []

    init(replies: [[UInt8]] = []) {
        self.replies = replies
    }

    /// A well-formed "Get VCP Feature Reply" for luminance, checksum included.
    static func luminanceReply(current: UInt16, maximum: UInt16, corruptChecksum: Bool = false)
        -> [UInt8]
    {
        var frame: [UInt8] = [
            0x88, 0x02, 0x00, DDC.luminance, 0x00,
            UInt8(maximum >> 8), UInt8(maximum & 0xFF),
            UInt8(current >> 8), UInt8(current & 0xFF),
        ]
        let checksum = frame.reduce(UInt8(0x50 ^ 0x6E), ^)
        frame.append(corruptChecksum ? checksum ^ 0xFF : checksum)
        return frame
    }

    func send(_ frame: [UInt8]) -> Int32 {
        sent.append(frame)
        return sendStatus
    }

    func request(_ frame: [UInt8], replyLength: Int) -> (status: Int32, bytes: [UInt8]) {
        defer { requestCount += 1 }
        guard !replies.isEmpty else { return (requestStatus, []) }
        return (requestStatus, replies[min(requestCount, replies.count - 1)])
    }
}

final class FakeDDCLinks: DDCLinks, @unchecked Sendable {
    var links: [CGDirectDisplayID: FakeDDCLink]
    private(set) var configurationChanges = 0

    init(_ links: [CGDirectDisplayID: FakeDDCLink] = [:]) {
        self.links = links
    }

    func link(for id: CGDirectDisplayID) -> (any DDCLink)? { links[id] }
    func configurationDidChange() { configurationChanges += 1 }
}

/// Runs queued work only when the test says so, and records requested delays.
final class ManualExecutor: BrightnessExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [@Sendable () -> Void] = []
    private(set) var delays: [Double] = []

    func run(_ work: @escaping @Sendable () -> Void) {
        lock.lock()
        queued.append(work)
        lock.unlock()
    }

    func run(afterSeconds delay: Double, _ work: @escaping @Sendable () -> Void) {
        lock.lock()
        delays.append(delay)
        queued.append(work)
        lock.unlock()
    }

    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return queued.count
    }

    /// Runs what is queued right now. Work queued while running waits for the
    /// next call, so a timer that re-arms itself cannot spin forever against a
    /// clock the test has not advanced.
    func runPending() {
        lock.lock()
        let batch = queued
        queued.removeAll()
        lock.unlock()
        for work in batch { work() }
    }
}
