import Foundation
import Testing

@testable import DisplayCore

/// The transfer functions are `@convention(c)`, which cannot capture, so what the
/// link did to the bus is recorded here. The suite is serialised for that reason.
private enum Bus {
    nonisolated(unsafe) static var writes: [[UInt8]] = []
    nonisolated(unsafe) static var reads = 0
    nonisolated(unsafe) static var failWriteNumber: Int?

    static func reset(failWriteNumber: Int? = nil) {
        writes = []
        reads = 0
        self.failWriteNumber = failWriteNumber
    }
}

private func makeLink() -> IOAVServiceLink {
    IOAVServiceLink(
        service: NSObject(),
        write: { _, _, _, buffer, length in
            Bus.writes.append(Array(UnsafeBufferPointer(start: buffer.assumingMemoryBound(to: UInt8.self), count: Int(length))))
            return Bus.writes.count == Bus.failWriteNumber ? -1 : 0
        },
        read: { _, _, _, buffer, length in
            Bus.reads += 1
            let canned: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32, 0xF2, 0x00]
            for index in 0..<Int(length) { buffer.storeBytes(of: canned[index], toByteOffset: index, as: UInt8.self) }
            return 0
        })
}

@Suite(.serialized)
struct IOAVServiceLinkTests {
    @Test func aRequestPutsTheFrameOnTheBusTwiceBeforeReading() {
        Bus.reset()
        let frame = DDC.getVCP(DDC.luminance)

        let answer = makeLink().request(frame, replyLength: 12)

        #expect(Bus.writes == [frame, frame])
        #expect(Bus.reads == 1)
        #expect(answer.status == 0)
        #expect(answer.bytes.count == 12)
    }

    @Test func aSendPutsTheFrameOnTheBusTwice() {
        Bus.reset()
        let frame = DDC.setVCP(DDC.luminance, value: 40)

        let status = makeLink().send(frame)

        #expect(Bus.writes == [frame, frame])
        #expect(status == 0)
    }

    @Test func aRefusedWriteIsNotRepeatedAndNothingIsRead() {
        Bus.reset(failWriteNumber: 1)

        let answer = makeLink().request(DDC.getVCP(DDC.luminance), replyLength: 12)

        #expect(Bus.writes.count == 1)
        #expect(Bus.reads == 0)
        #expect(answer.status == -1)
        #expect(answer.bytes.isEmpty)
    }

    @Test func aRefusedRepeatIsReportedAndNothingIsRead() {
        Bus.reset(failWriteNumber: 2)

        let answer = makeLink().request(DDC.getVCP(DDC.luminance), replyLength: 12)

        #expect(Bus.writes.count == 2)
        #expect(Bus.reads == 0)
        #expect(answer.status == -1)
    }
}
