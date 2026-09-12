import XCTest
import CoreMedia
import VideoToolbox
@testable import IPadScreenCore

final class ProtocolTests: XCTestCase {
    func testAuthenticationMatchesExistingReceiver() throws {
        let hello = try ReceiverProtocol.hello(token: String(repeating: "a", count: 64))
        XCTAssertEqual(hello.count, 72)
        XCTAssertEqual(String(decoding: hello.prefix(8), as: UTF8.self), "IPDS0001")
        for value in ["", String(repeating: "g", count: 64), String(repeating: "a", count: 65), String(repeating: "é", count: 64)] {
            XCTAssertThrowsError(try ReceiverProtocol.hello(token: value))
        }
    }
    func testPacketContainsBigEndianLengthAndCompleteNALs() throws {
        let avcc = Data([0, 0, 0, 2, 0x67, 1, 0, 0, 0, 3, 0x65, 2, 3])
        XCTAssertEqual(try ReceiverProtocol.packet(avcc), Data([0,0,0,13]) + avcc)
        for malformed in [Data(), Data([0,0,0]), Data([0,0,0,0]), Data([0,0,0,3,0x65]), Data(repeating: 0, count: ReceiverProtocol.maximumFrame + 1)] {
            XCTAssertThrowsError(try ReceiverProtocol.packet(malformed))
        }
    }
    func testAcknowledgmentValidatesReservedFieldAndCounters() throws {
        let bytes = Data([0,0,0,9, 0,0,0,0, 0,0,0,8, 0,0,0,1])
        let ack = try ReceiverAck(data: bytes)
        XCTAssertEqual(ack.received, 9); XCTAssertEqual(ack.enqueued, 8); XCTAssertEqual(ack.errors, 1)
        XCTAssertThrowsError(try ReceiverAck(data: bytes.dropLast()))
        var reserved = bytes; reserved[7] = 1
        XCTAssertThrowsError(try ReceiverAck(data: reserved))
        var impossible = bytes; impossible[11] = 10
        XCTAssertThrowsError(try ReceiverAck(data: impossible))
    }
    func testUSBMuxRejectsUntrustedHeadersBeforeReadingPayload() throws {
        var good = Data()
        for value: UInt32 in [128, 1, 8, 1] { good.appendUInt32(value, bigEndian: false) }
        XCTAssertEqual(try USBMux.responseLength(header: good), 112)
        for index in [0,4,8,12] {
            var invalid = good; invalid[index] = 0
            XCTAssertThrowsError(try USBMux.responseLength(header: invalid))
        }
        var huge = good; huge[3] = 0xff
        XCTAssertThrowsError(try USBMux.responseLength(header: huge))
        XCTAssertThrowsError(try USBMux.responseLength(header: good.dropLast()))
    }
    func sockets() throws -> (LocalSocket, LocalSocket) {
        var fds: [Int32] = [-1,-1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        return (try LocalSocket(fd: fds[0]), try LocalSocket(fd: fds[1]))
    }
    func testPartialWritesAndFragmentedReadsPreserveLargePayload() throws {
        let (a,b) = try sockets()
        var small: Int32 = 4096
        setsockopt(a.fd, SOL_SOCKET, SO_SNDBUF, &small, 4)
        let payload = Data((0..<(2 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0) })
        let sent = expectation(description: "all bytes sent")
        DispatchQueue.global().async {
            do { try a.writeAll(payload) } catch { XCTFail(error.localizedDescription) }
            sent.fulfill()
        }
        var received = Data()
        while received.count < payload.count { received.append(try b.readExactly(min(113, payload.count - received.count))) }
        XCTAssertEqual(received, payload)
        wait(for: [sent], timeout: 10)
    }
    func testPeerDisconnectAndCancellationUnblockReads() throws {
        let (a,b) = try sockets()
        try b.writeAll(Data([1,2]))
        b.cancel()
        XCTAssertThrowsError(try a.readExactly(4))
        let (c,d) = try sockets()
        let done = expectation(description: "cancelled read")
        DispatchQueue.global().async {
            do { _ = try c.readExactly(16); XCTFail("Cancelled read should fail") } catch {}
            done.fulfill()
        }
        c.cancel(); _ = d
        wait(for: [done], timeout: 1)
    }
    func testProfileRoundTripPreservesOtherDevicesAndPrivatePermissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try StateStore(root: root)
        let one = DeviceProfile(udid: "aabb11", key: "/test/key", model: .pro97, tokenFile: "token-a")
        let two = DeviceProfile(udid: "ccdd22", key: "/test/key", model: .pro105, tokenFile: "token-b")
        try store.save(one, token: String(repeating: "a", count: 64))
        try store.save(two, token: String(repeating: "b", count: 64))
        XCTAssertEqual(try store.profiles().count, 2)
        XCTAssertEqual(try store.activeProfile(), two)
        XCTAssertEqual(try store.token(for: one), String(repeating: "a", count: 64))
        let attrs = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("token-a").path)
        XCTAssertEqual(attrs[.posixPermissions] as? Int, 0o600)
        let traversal = DeviceProfile(udid: "aabb11", key: "/test/key", model: .pro97, tokenFile: "../outside")
        XCTAssertThrowsError(try store.save(traversal, token: String(repeating: "a", count: 64)))
        XCTAssertThrowsError(try store.token(for: traversal))
    }
    func testRealH264EncodingAndOneFrameBackpressure() async throws {
        let (host, receiver) = try sockets()
        let pipeline = try VideoPipeline(socket: host, width: 320, height: 240, fps: 30, bitrate: 4_000_000, mode: "test",
            report: { _ in }, failure: { XCTFail($0.localizedDescription) })
        let pattern = TestPattern(pipeline: pipeline, width: 320, height: 240, fps: 30)
        let length = Int(try receiver.readExactly(4).uint32(at: 0))
        let avcc = try receiver.readExactly(length)
        var offset = 0, nals: [Data] = []
        while offset < avcc.count {
            let size = Int(avcc.uint32(at: offset)); offset += 4
            nals.append(Data(avcc[offset..<(offset + size)])); offset += size
        }
        XCTAssertTrue(nals.contains { $0.first! & 31 == 7 }, "SPS is sent before the first picture")
        XCTAssertTrue(nals.contains { $0.first! & 31 == 8 }, "PPS is sent before the first picture")
        XCTAssertTrue(nals.contains { $0.first! & 31 == 5 }, "First picture must be an IDR")
        try decodeFirstFrame(nals, width: 320, height: 240)
        // Withhold ACK while raw frames arrive. No second compressed frame may be sent.
        try await Task.sleep(nanoseconds: 250_000_000)
        var descriptor = pollfd(fd: receiver.fd, events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(poll(&descriptor, 1, 0), 0)
        try receiver.writeAll(Data([0,0,0,1, 0,0,0,0, 0,0,0,1, 0,0,0,0]))
        let nextLength = Int(try receiver.readExactly(4).uint32(at: 0))
        XCTAssertGreaterThan(try receiver.readExactly(nextLength).count, 0)
        try receiver.writeAll(Data([0,0,0,2, 0,0,0,0, 0,0,0,2, 0,0,0,0]))
        pattern.stop()
        let stats = await pipeline.stop()
        XCTAssertGreaterThan(stats.framesSkipped, 0)
    }
    private func decodeFirstFrame(_ nals: [Data], width: Int, height: Int) throws {
        let sps = nals.first { $0[0] & 31 == 7 }!, pps = nals.first { $0[0] & 31 == 8 }!
        var format: CMFormatDescription?
        let result = sps.withUnsafeBytes { s in pps.withUnsafeBytes { p -> OSStatus in
            let pointers = [s.baseAddress!.assumingMemoryBound(to: UInt8.self), p.baseAddress!.assumingMemoryBound(to: UInt8.self)]
            let sizes = [sps.count, pps.count]
            return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2,
                parameterSetPointers: pointers, parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
        } }
        XCTAssertEqual(result, noErr)
        let dimensions = CMVideoFormatDescriptionGetDimensions(format!)
        XCTAssertEqual(Int(dimensions.width), width); XCTAssertEqual(Int(dimensions.height), height)
        var picture = Data()
        for nal in nals where ![7,8].contains(nal[0] & 31) { picture.appendUInt32(UInt32(nal.count)); picture.append(nal) }
        var block: CMBlockBuffer?, sample: CMSampleBuffer?, decoder: VTDecompressionSession?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: picture.count,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: picture.count, flags: 0, blockBufferOut: &block), noErr)
        XCTAssertEqual(picture.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: picture.count) }, noErr)
        var size = picture.count
        XCTAssertEqual(CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample), noErr)
        XCTAssertEqual(VTDecompressionSessionCreate(allocator: nil, formatDescription: format!, decoderSpecification: nil,
            imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &decoder), noErr)
        defer { if let decoder { VTDecompressionSessionInvalidate(decoder) } }
        let decoded = expectation(description: "H.264 decoded to pixels")
        XCTAssertEqual(VTDecompressionSessionDecodeFrame(decoder!, sampleBuffer: sample!, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
            XCTAssertEqual(status, noErr); XCTAssertNotNil(image)
            if let image { XCTAssertEqual(CVPixelBufferGetWidth(image), width); XCTAssertEqual(CVPixelBufferGetHeight(image), height) }
            decoded.fulfill()
        }, noErr)
        VTDecompressionSessionWaitForAsynchronousFrames(decoder!)
        wait(for: [decoded], timeout: 5)
    }
}
