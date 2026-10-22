import CoreGraphics
import Foundation
import IOKit

/// Real DDC transport for Apple silicon: `IOAVService` over a
/// `DCPAVServiceProxy`. Not unit-tested — it is the part that talks to a monitor,
/// and is verified by a human at the keyboard (spec §18.9). The pure decisions it
/// feeds (`DDCMatching`, `DDCBackend`) are tested.
///
/// How a display reaches its service, found on the development machine rather than
/// assumed (spec §18.4): a `DCPAVServiceProxy` with `Location = External` has an
/// ancestor named `dispextN:dcpav-service-epic:0`; the device node `dispextN` has an
/// `AppleCLCD2` child whose `DisplayAttributes.ProductAttributes` carry
/// `LegacyManufacturerID`, `ProductID` and `SerialNumber` — the same three numbers
/// `CGDisplayVendorNumber`, `CGDisplayModelNumber` and `CGDisplaySerialNumber`
/// return. `N` links the two nodes; the three numbers link the node to a display.
public final class IOAVServiceLinks: DDCLinks, @unchecked Sendable {
    private typealias CreateFunction = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    typealias TransferFunction = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> Int32

    private let create: CreateFunction?
    private let write: TransferFunction?
    private let read: TransferFunction?

    private let lock = NSLock()
    /// `nil` until first asked, and again after `configurationDidChange`.
    private var built: [CGDirectDisplayID: IOAVServiceLink]?

    public init() {
        let handle = BrightnessBridge.open("/System/Library/Frameworks/IOKit.framework/IOKit")
        create = BrightnessBridge.function("IOAVServiceCreateWithService", in: handle, as: CreateFunction.self)
        write = BrightnessBridge.function("IOAVServiceWriteI2C", in: handle, as: TransferFunction.self)
        read = BrightnessBridge.function("IOAVServiceReadI2C", in: handle, as: TransferFunction.self)
    }

    public func link(for id: CGDirectDisplayID) -> (any DDCLink)? {
        lock.lock()
        defer { lock.unlock() }
        if built == nil { built = build() }
        return built?[id]
    }

    public func configurationDidChange() {
        lock.lock()
        built = nil
        lock.unlock()
    }

    /// The `N` in a service name like `dispext0:dcpav-service-epic:0`.
    static func displayIndex(inServiceName name: String) -> Int? {
        let prefix = "dispext"
        guard name.hasPrefix(prefix), let colon = name.firstIndex(of: ":") else { return nil }
        return Int(name[name.index(name.startIndex, offsetBy: prefix.count)..<colon])
    }

    private func build() -> [CGDirectDisplayID: IOAVServiceLink] {
        guard let create, let write, let read else { return [:] }

        let services = externalServices()
        defer { for service in services { IOObjectRelease(service.proxy) } }

        let hardwareByIndex = framebufferHardware()
        let matched = DDCMatching.assign(
            displays: onlineDisplays(),
            services: services.compactMap { service in
                hardwareByIndex[service.index].map { (token: service.index, hardware: $0) }
            })

        var links: [CGDirectDisplayID: IOAVServiceLink] = [:]
        for (id, index) in matched {
            guard let proxy = services.first(where: { $0.index == index })?.proxy,
                let ref = create(kCFAllocatorDefault, proxy)?.takeRetainedValue()
            else { continue }
            links[id] = IOAVServiceLink(service: ref, write: write, read: read)
        }
        return links
    }

    private func onlineDisplays() -> [CGDirectDisplayID: DisplayHardwareID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        var result: [CGDirectDisplayID: DisplayHardwareID] = [:]
        for id in ids.prefix(Int(count)) where CGDisplayIsBuiltin(id) == 0 {
            result[id] = DisplayHardwareID(
                vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id),
                serial: CGDisplaySerialNumber(id))
        }
        return result
    }

    /// External `DCPAVServiceProxy` entries and the `dispextN` index each hangs
    /// under. The caller releases `proxy`.
    private func externalServices() -> [(index: Int, proxy: io_service_t)] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }

        var found: [(index: Int, proxy: io_service_t)] = []
        while case let proxy = IOIteratorNext(iterator), proxy != 0 {
            let location = property(proxy, "Location") as? String
            guard location == "External", let index = displayIndex(above: proxy) else {
                IOObjectRelease(proxy)
                continue
            }
            found.append((index, proxy))
        }
        return found
    }

    /// Walks up from `entry` looking for the `dispextN:…` ancestor.
    private func displayIndex(above entry: io_registry_entry_t) -> Int? {
        var current = entry
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }
        for _ in 0..<6 {
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS
            else { return nil }
            IOObjectRelease(current)
            current = parent
            if let index = Self.displayIndex(inServiceName: name(of: current)) { return index }
        }
        return nil
    }

    /// For each `dispextN` device node, the hardware ID its `AppleCLCD2` child
    /// reports. A node whose children disagree is left out rather than guessed.
    private func framebufferHardware() -> [Int: DisplayHardwareID] {
        var iterator: io_iterator_t = 0
        guard IORegistryCreateIterator(
            kIOMainPortDefault, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively),
            &iterator) == KERN_SUCCESS
        else { return [:] }
        defer { IOObjectRelease(iterator) }

        var result: [Int: DisplayHardwareID] = [:]
        while case let node = IOIteratorNext(iterator), node != 0 {
            defer { IOObjectRelease(node) }
            let nodeName = name(of: node)
            guard nodeName.hasPrefix("dispext"), !nodeName.contains(":"),
                let index = Int(nodeName.dropFirst("dispext".count))
            else { continue }

            var children: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(node, kIOServicePlane, &children) == KERN_SUCCESS
            else { continue }
            var ids: Set<DisplayHardwareID> = []
            while case let child = IOIteratorNext(children), child != 0 {
                if let id = hardwareID(of: child) { ids.insert(id) }
                IOObjectRelease(child)
            }
            IOObjectRelease(children)
            if ids.count == 1, let only = ids.first { result[index] = only }
        }
        return result
    }

    private func hardwareID(of entry: io_registry_entry_t) -> DisplayHardwareID? {
        guard let attributes = property(entry, "DisplayAttributes") as? [String: Any],
            let product = attributes["ProductAttributes"] as? [String: Any],
            let vendor = (product["LegacyManufacturerID"] as? NSNumber)?.uint32Value,
            let model = (product["ProductID"] as? NSNumber)?.uint32Value,
            let serial = (product["SerialNumber"] as? NSNumber)?.uint32Value
        else { return nil }
        return DisplayHardwareID(vendor: vendor, model: model, serial: serial)
    }

    private func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
    }

    private func name(of entry: io_registry_entry_t) -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        IORegistryEntryGetName(entry, &buffer)
        return String(cString: buffer)
    }
}

/// One monitor's I²C channel. Serialises its own transfers: a request is a write,
/// a wait and a read, and another caller's frame in the middle would corrupt it.
final class IOAVServiceLink: DDCLink, @unchecked Sendable {
    /// How long a monitor is given to compose its reply.
    static let settleMicroseconds: UInt32 = 50_000

    /// How many times a frame goes out, and the pause between copies. The LG
    /// silently drops the first write of a transaction after it has been idle or
    /// asleep: one Get-VCP is answered with a bare null message at every settle
    /// time up to 500 ms, two 10 ms apart are answered at once. Both kinds of
    /// frame are idempotent (a Get reads, a Set carries an absolute value), so
    /// the repeat costs nothing when the first copy did arrive.
    static let writeCycles = 2
    static let writeGapMicroseconds: UInt32 = 10_000

    private let service: CFTypeRef
    private let write: IOAVServiceLinks.TransferFunction
    private let read: IOAVServiceLinks.TransferFunction
    private let lock = NSLock()

    init(
        service: CFTypeRef, write: @escaping IOAVServiceLinks.TransferFunction,
        read: @escaping IOAVServiceLinks.TransferFunction
    ) {
        self.service = service
        self.write = write
        self.read = read
    }

    func send(_ frame: [UInt8]) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        return transmit(frame)
    }

    func request(_ frame: [UInt8], replyLength: Int) -> (status: Int32, bytes: [UInt8]) {
        lock.lock()
        defer { lock.unlock() }
        let written = transmit(frame)
        guard written == 0 else { return (written, []) }

        usleep(Self.settleMicroseconds)
        var reply = [UInt8](repeating: 0, count: replyLength)
        // The read offset is a guess: the spike read the same bytes at 0x0, 0x37
        // and 0x51, so it cannot be told from that. 0x51 mirrors the write.
        let status = read(service, DDC.chipAddress, DDC.dataAddress, &reply, UInt32(replyLength))
        return (status, reply)
    }

    /// Caller holds `lock`. Stops at the first copy the bus refuses.
    private func transmit(_ frame: [UInt8]) -> Int32 {
        var frame = frame
        for cycle in 0..<Self.writeCycles {
            if cycle > 0 { usleep(Self.writeGapMicroseconds) }
            let status = write(service, DDC.chipAddress, DDC.dataAddress, &frame, UInt32(frame.count))
            if status != 0 { return status }
        }
        return 0
    }
}
