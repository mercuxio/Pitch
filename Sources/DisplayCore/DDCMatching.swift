import CoreGraphics

/// The three numbers CoreGraphics and the IORegistry both report for a monitor,
/// and the only thing this app can use to say "this display is that service"
/// (spec §18.4).
public struct DisplayHardwareID: Hashable, Sendable {
    public let vendor: UInt32
    public let model: UInt32
    public let serial: UInt32

    public init(vendor: UInt32, model: UInt32, serial: UInt32) {
        self.vendor = vendor
        self.model = model
        self.serial = serial
    }
}

/// Pairs displays with DDC services. Pure, so the one rule that decides whether
/// a brightness write lands on the right monitor is testable without one.
public enum DDCMatching {
    /// A display gets a service only if **exactly one** online display and
    /// **exactly one** service carry its hardware ID. Anything else is left out:
    /// two identical monitors cannot be told apart by these numbers, and guessing
    /// would dim the wrong one. A display left out falls through to gamma.
    public static func assign<Token: Hashable>(
        displays: [CGDirectDisplayID: DisplayHardwareID],
        services: [(token: Token, hardware: DisplayHardwareID)]
    ) -> [CGDirectDisplayID: Token] {
        var displayCount: [DisplayHardwareID: Int] = [:]
        for hardware in displays.values { displayCount[hardware, default: 0] += 1 }

        var serviceCount: [DisplayHardwareID: Int] = [:]
        var tokenFor: [DisplayHardwareID: Token] = [:]
        for service in services {
            serviceCount[service.hardware, default: 0] += 1
            tokenFor[service.hardware] = service.token
        }

        var assigned: [CGDirectDisplayID: Token] = [:]
        for (id, hardware) in displays
        where displayCount[hardware] == 1 && serviceCount[hardware] == 1 {
            assigned[id] = tokenFor[hardware]
        }
        return assigned
    }
}
