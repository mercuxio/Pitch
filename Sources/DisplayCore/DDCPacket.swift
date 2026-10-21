/// MCCS over DDC/CI: the bytes for reading and writing a monitor's luminance,
/// and the parser for its reply (spec §18.4). Pure — no I/O, no IOKit.
///
/// The layouts below are derived from the VESA DDC/CI and MCCS descriptions and
/// from published open-source implementations, not from recorded traffic.
/// `displayctl brightness` against real hardware is what confirms them; until
/// then a reply that does not parse is treated as "not readable", never guessed.
public enum DDC {
    /// 7-bit I²C address of the DDC/CI endpoint.
    public static let chipAddress: UInt32 = 0x37
    /// The host's source address, passed to `IOAVServiceWriteI2C` as the data
    /// address rather than being part of the buffer.
    public static let dataAddress: UInt32 = 0x51
    /// MCCS VCP feature: luminance.
    public static let luminance: UInt8 = 0x10

    private static let destinationWrite: UInt8 = 0x6E  // 0x37 << 1
    private static let hostAddress: UInt8 = 0x50       // replies are addressed here
    private static let sourceMonitor: UInt8 = 0x6E

    private static let setOpcode: UInt8 = 0x03
    private static let getOpcode: UInt8 = 0x01
    private static let replyOpcode: UInt8 = 0x02

    /// "Set VCP Feature": the buffer for `IOAVServiceWriteI2C`.
    public static func setVCP(_ code: UInt8, value: UInt16) -> [UInt8] {
        framed([setOpcode, code, UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    /// "Get VCP Feature" request.
    public static func getVCP(_ code: UInt8) -> [UInt8] {
        framed([getOpcode, code])
    }

    /// Prefixes the length byte and appends the checksum. The checksum covers the
    /// destination address and the source address as well, though neither is in
    /// the buffer.
    private static func framed(_ payload: [UInt8]) -> [UInt8] {
        var frame = [0x80 | UInt8(payload.count)] + payload
        let seed = destinationWrite ^ UInt8(truncatingIfNeeded: dataAddress)
        frame.append(frame.reduce(seed, ^))
        return frame
    }

    /// The raw value to send for `level`, given the monitor's own maximum.
    public static func rawValue(for level: BrightnessLevel, maximum: UInt16) -> UInt16 {
        UInt16((level.value * Double(maximum)).rounded())
    }

    public struct Reply: Equatable, Sendable {
        public let code: UInt8
        public let current: UInt16
        public let maximum: UInt16
        /// False when the frame's checksum did not match. Reported rather than
        /// thrown on, so a diagnostic can show a frame that is nearly right.
        public let checksumValid: Bool

        /// `current / maximum`, or `nil` if the monitor reported a maximum of 0.
        public var level: BrightnessLevel? {
            maximum == 0 ? nil : BrightnessLevel(Double(current) / Double(maximum))
        }
    }

    public enum FrameError: Error, Equatable, Sendable {
        case tooShort
        case notAGetReply
        /// The monitor answered, but says it does not implement the feature.
        case unsupportedFeature
        case wrongFeature(UInt8)
    }

    /// Parses a "Get VCP Feature Reply" for `code`.
    ///
    /// Accepts the frame with or without its leading source byte (`0x6E`):
    /// which of the two `IOAVServiceReadI2C` returns is one of the things the
    /// hardware spike settles, and the two cannot be confused — one starts with
    /// `0x6E`, the other with the length byte `0x88`.
    public static func parseReply(_ bytes: [UInt8], expecting code: UInt8) throws -> Reply {
        var frame = bytes[...]
        if frame.first == sourceMonitor { frame = frame.dropFirst() }
        guard frame.count >= 10 else { throw FrameError.tooShort }

        let b = Array(frame.prefix(10))  // length, opcode, result, vcp, type, maxH, maxL, curH, curL, checksum
        guard b[0] == 0x88, b[1] == replyOpcode else { throw FrameError.notAGetReply }
        guard b[2] == 0x00 else { throw FrameError.unsupportedFeature }
        guard b[3] == code else { throw FrameError.wrongFeature(b[3]) }

        let expected = b[0..<9].reduce(hostAddress ^ sourceMonitor, ^)
        return Reply(
            code: b[3],
            current: UInt16(b[7]) << 8 | UInt16(b[8]),
            maximum: UInt16(b[5]) << 8 | UInt16(b[6]),
            checksumValid: expected == b[9])
    }
}
