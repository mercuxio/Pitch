import CoreGraphics
import Foundation

/// The two DisplayServices calls Apple panels answer to, as a seam: tests drive
/// the backend's logic without a panel, and a missing symbol is just
/// `isAvailable == false`.
public protocol DisplayServicesCalls: Sendable {
    var isAvailable: Bool { get }
    /// `status` is the call's own return value; 0 is success. `value` is 0...1.
    func get(_ id: CGDirectDisplayID) -> (status: Int32, value: Float)
    /// The call's own return value; 0 is success.
    func set(_ id: CGDirectDisplayID, _ value: Float) -> Int32
}

/// Apple's own brightness path (spec §18.2): the built-in panel, and Apple's
/// external displays. Preferred above everything else because it is the same
/// mechanism the keyboard keys use, so the system's slider and Pitch's agree.
public final class DisplayServicesBackend: BrightnessBackend, @unchecked Sendable {
    public let method = BrightnessMethod.appleDisplay

    private let calls: any DisplayServicesCalls

    public init(calls: any DisplayServicesCalls) {
        self.calls = calls
    }

    /// Supported only if the symbols resolve **and** a real read comes back
    /// sensible. A third-party monitor is expected to fail the read; claiming it
    /// anyway would trap the display on a backend that cannot drive it, ahead of
    /// DDC, which can. Reads only.
    public func probe(_ id: CGDirectDisplayID) -> BrightnessProbe {
        guard calls.isAvailable else { return .unsupported }
        let reply = calls.get(id)
        guard reply.status == 0, (0...1).contains(reply.value) else { return .unsupported }
        return .supported(readable: true)
    }

    public func level(for id: CGDirectDisplayID) throws -> BrightnessLevel? {
        let reply = calls.get(id)
        guard reply.status == 0, (0...1).contains(reply.value) else {
            throw DisplayError.brightnessUnsupported(id)
        }
        return BrightnessLevel(Double(reply.value))
    }

    public func setLevel(_ level: BrightnessLevel, for id: CGDirectDisplayID) throws {
        let status = calls.set(id, Float(level.value))
        guard status == 0 else { throw DisplayError.brightnessWriteFailed(id, code: status) }
    }
}

/// The real thing: resolves the private symbols once, at first use. Not
/// unit-tested; it is exactly the part that touches the panel, and is checked by
/// a human at the keyboard (spec §18.9).
public struct DynamicDisplayServices: DisplayServicesCalls, @unchecked Sendable {
    private typealias GetFunction = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFunction = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private let getFunction: GetFunction?
    private let setFunction: SetFunction?

    public init() {
        let handle = BrightnessBridge.open(
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices")
        getFunction = BrightnessBridge.function(
            "DisplayServicesGetBrightness", in: handle, as: GetFunction.self)
        setFunction = BrightnessBridge.function(
            "DisplayServicesSetBrightness", in: handle, as: SetFunction.self)
    }

    public var isAvailable: Bool { getFunction != nil && setFunction != nil }

    public func get(_ id: CGDirectDisplayID) -> (status: Int32, value: Float) {
        guard let getFunction else { return (-1, 0) }
        var value: Float = 0
        let status = getFunction(id, &value)
        return (status, value)
    }

    public func set(_ id: CGDirectDisplayID, _ value: Float) -> Int32 {
        setFunction?(id, value) ?? -1
    }
}
