import CoreGraphics
import Foundation

/// One monitor's DDC/CI bus, as a seam: the backend's logic is tested against
/// scripted bytes, and the real implementation owns the I²C timing.
public protocol DDCLink: Sendable {
    /// Writes one frame. 0 is success, anything else is the transport's code.
    func send(_ frame: [UInt8]) -> Int32

    /// Writes a request, waits for the monitor to compose its answer, and reads
    /// `replyLength` bytes. The wait belongs here, not in the backend: the
    /// backend never sleeps.
    func request(_ frame: [UInt8], replyLength: Int) -> (status: Int32, bytes: [UInt8])
}

/// Finds the link for a display. Returns `nil` when no service maps to it
/// unambiguously (spec §18.4), which is not an error — the display simply goes
/// to the next backend.
public protocol DDCLinks: Sendable {
    func link(for id: CGDirectDisplayID) -> (any DDCLink)?
    /// Drops whatever is cached against display IDs.
    func configurationDidChange()
}

/// A third-party monitor's own backlight, over DDC/CI (spec §18.2, §18.4).
public final class DDCBackend: BrightnessBackend, @unchecked Sendable {
    public let method = BrightnessMethod.ddc

    /// A monitor's reply is 11 bytes, or 10 without the leading source byte;
    /// one spare byte costs nothing.
    static let replyLength = 12
    /// A probe asks twice, so one lost frame on a shared bus does not send a
    /// working monitor to software dimming.
    static let probeAttempts = 2
    /// After this many reads in a row go unanswered the display is treated as
    /// write-only until the configuration changes (spec §18.4).
    static let readFailureLimit = 3

    private let links: any DDCLinks
    private let lock = NSLock()
    private var maximums: [CGDirectDisplayID: UInt16] = [:]
    private var failedReads: [CGDirectDisplayID: Int] = [:]

    public init(links: any DDCLinks) {
        self.links = links
    }

    /// Supported only on a **valid answer**: a reply that parses, passes its
    /// checksum and reports a non-zero maximum. A bus that is silent, or fills
    /// the buffer with a constant, is not a monitor that can be dimmed, and
    /// claiming it would leave the slider moving nothing instead of falling
    /// through to gamma. The only frame sent is the read request, which changes
    /// nothing on the monitor.
    public func probe(_ id: CGDirectDisplayID) -> BrightnessProbe {
        guard let link = links.link(for: id) else { return .unsupported }
        for _ in 0..<Self.probeAttempts {
            if let reply = readReply(from: link) {
                record(reply, for: id)
                return .supported(readable: true)
            }
        }
        return .unsupported
    }

    /// `nil` on an unanswered read. Not an error: the slider keeps working, and
    /// after `readFailureLimit` misses the bus is no longer asked at all.
    public func level(for id: CGDirectDisplayID) throws -> BrightnessLevel? {
        guard let link = links.link(for: id) else { throw DisplayError.brightnessUnsupported(id) }

        lock.lock()
        let writeOnly = failedReads[id, default: 0] >= Self.readFailureLimit
        lock.unlock()
        if writeOnly { return nil }

        if let reply = readReply(from: link) {
            record(reply, for: id)
            return reply.level
        }
        lock.lock()
        failedReads[id, default: 0] += 1
        lock.unlock()
        return nil
    }

    public func setLevel(_ level: BrightnessLevel, for id: CGDirectDisplayID) throws {
        guard let link = links.link(for: id) else { throw DisplayError.brightnessUnsupported(id) }

        // The monitor's own maximum, remembered from the probe. Re-read only if
        // it was never learned; a write scaled against an assumed 100 would be
        // wrong on any monitor whose range differs.
        lock.lock()
        let known = maximums[id]
        lock.unlock()
        guard let maximum = known ?? readReply(from: link)?.maximum else {
            throw DisplayError.brightnessUnsupported(id)
        }

        let raw = DDC.rawValue(for: level, maximum: maximum)
        let status = link.send(DDC.setVCP(DDC.luminance, value: raw))
        guard status == 0 else { throw DisplayError.brightnessWriteFailed(id, code: status) }
    }

    public func configurationDidChange() {
        lock.lock()
        maximums.removeAll()
        failedReads.removeAll()
        lock.unlock()
        links.configurationDidChange()
    }

    private func readReply(from link: any DDCLink) -> DDC.Reply? {
        let answer = link.request(
            DDC.getVCP(DDC.luminance), replyLength: Self.replyLength)
        guard answer.status == 0,
            let reply = try? DDC.parseReply(answer.bytes, expecting: DDC.luminance),
            reply.checksumValid, reply.maximum > 0
        else { return nil }
        return reply
    }

    private func record(_ reply: DDC.Reply, for id: CGDirectDisplayID) {
        lock.lock()
        maximums[id] = reply.maximum
        failedReads[id] = 0
        lock.unlock()
    }
}
