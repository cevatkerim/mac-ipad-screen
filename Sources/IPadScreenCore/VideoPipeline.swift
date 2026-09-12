import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
import ScreenCaptureKit

public struct SessionStatistics: Codable {
    public var framesSent = 0
    public var bytesSent = 0
    public var framesSkipped = 0
    public var receiver: ReceiverAck?
    public var elapsedSeconds = 0.0
    public var hardwareEncoder = false
    public var width = 0
    public var height = 0
    public var mode = ""
    public var requestedFPS = 30
    public var averageFPS: Double { Double(framesSent) / max(0.001, elapsedSeconds) }
    public init() {}
}

/// The capture queue owns all state. Only one raw frame can enter the encoder
/// until the receiver acknowledges its result. Skips happen BEFORE encoding,
/// preserving the H.264 reference chain and keeping memory/latency bounded.
final class VideoPipeline: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "ipad-screen.capture", qos: .userInteractive)
    private let wireQueue = DispatchQueue(label: "ipad-screen.usb", qos: .userInteractive)
    private let socket: LocalSocket
    private var encoder: VTCompressionSession?
    private var timer: DispatchSourceTimer?
    private var latestImage: CVPixelBuffer?
    private var imageRevision: UInt64 = 0
    private var encodingRevision: UInt64 = 0
    private var busy = false
    private var stopped = false
    private var lastSubmitted = 0.0
    private var lastKeyframe = 0.0
    private var forceKeyframe = true
    private var started = ProcessInfo.processInfo.systemUptime
    private var lastReport = 0.0
    private let fps: Int
    private var statistics: SessionStatistics
    private let report: (SessionStatistics) -> Void
    private let failure: (Error) -> Void

    init(socket: LocalSocket, width: Int, height: Int, fps: Int, bitrate: Int, mode: String,
         report: @escaping (SessionStatistics) -> Void, failure: @escaping (Error) -> Void) throws {
        self.socket = socket; self.fps = fps; self.report = report; self.failure = failure
        statistics = SessionStatistics()
        statistics.width = width; statistics.height = height; statistics.mode = mode; statistics.requestedFPS = fps
        super.init()
        let specification = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true] as CFDictionary
        try check(VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264, encoderSpecification: specification,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil,
            refcon: nil, compressionSessionOut: &encoder), "create H.264 encoder")
        do {
            try property(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
            try property(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
            try property(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
            try property(kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber)
            try property(kVTCompressionPropertyKey_AverageBitRate, bitrate as CFNumber)
            try property(kVTCompressionPropertyKey_MaxKeyFrameInterval, fps as CFNumber)
            try property(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 1 as CFNumber)
            try property(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
            try property(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
            try property(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
            try check(VTCompressionSessionPrepareToEncodeFrames(encoder!), "prepare H.264 encoder")
            var hardware: Unmanaged<CFTypeRef>?
            VTSessionCopyProperty(encoder!, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, allocator: nil, valueOut: &hardware)
            statistics.hardwareEncoder = (hardware?.takeRetainedValue() as? NSNumber)?.boolValue ?? false
        } catch { VTCompressionSessionInvalidate(encoder!); encoder = nil; throw error }
    }
    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw HostError("Could not \(operation) (VideoToolbox \(status)).") }
    }
    private func property(_ key: CFString, _ value: CFTypeRef) throws {
        try check(VTSessionSetProperty(encoder!, key: key, value: value), "configure H.264")
    }
    func startHeartbeat() {
        queue.async {
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in
                guard let self, !self.stopped else { return }
                if self.latestImage == nil && ProcessInfo.processInfo.systemUptime - self.started > 5 {
                    self.fail(HostError("No screen frames arrived. Check Screen Recording access and keep the Mac unlocked.")); return
                }
                guard let image = self.latestImage,
                      ProcessInfo.processInfo.systemUptime - self.lastSubmitted > 0.9 else { return }
                // Static ScreenCaptureKit content needs a keepalive for the receiver's timeout.
                self.offer(image)
            }
            self.timer = timer
            timer.resume()
        }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        offer(image)
    }
    func offer(_ image: CVPixelBuffer) {
        guard !stopped else { return }
        if busy && imageRevision > encodingRevision { statistics.framesSkipped += 1 }
        latestImage = image
        imageRevision &+= 1
        encodeLatest()
    }
    private func encodeLatest() {
        guard !busy, !stopped, let image = latestImage else { return }
        guard let encoder else { return }
        busy = true
        encodingRevision = imageRevision
        let now = ProcessInfo.processInfo.systemUptime
        let keyframe = forceKeyframe || now - lastKeyframe >= 1
        if keyframe { lastKeyframe = now; forceKeyframe = false }
        lastSubmitted = now
        let presentation = CMTime(seconds: now - started, preferredTimescale: 1_000_000)
        let properties = keyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let result = VTCompressionSessionEncodeFrame(encoder, imageBuffer: image, presentationTimeStamp: presentation,
            duration: CMTime(value: 1, timescale: Int32(fps)), frameProperties: properties, infoFlagsOut: nil) { [weak self] status, flags, sample in
                guard let self else { return }
                self.queue.async {
                    guard !self.stopped else { return }
                    if status != noErr { self.fail(HostError("H.264 encoding failed (\(status)).")); return }
                    guard !flags.contains(.frameDropped), let sample else { self.busy = false; self.forceKeyframe = true; return }
                    do { try self.send(sample) } catch { self.fail(error) }
                }
            }
        if result != noErr { fail(HostError("Could not submit a frame to H.264 (\(result)).")) }
    }
    static func avcc(_ sample: CMSampleBuffer) throws -> Data {
        guard let format = CMSampleBufferGetFormatDescription(sample), let block = CMSampleBufferGetDataBuffer(sample) else {
            throw HostError("The encoder returned an empty H.264 sample.")
        }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let keyframe = !((attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
        var data = Data()
        if keyframe {
            var count = 0, headerLength: Int32 = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &headerLength)
            guard status == noErr, headerLength == 4, (2...16).contains(count) else { throw HostError("Unsupported H.264 parameter sets.") }
            for index in 0..<count {
                var pointer: UnsafePointer<UInt8>?, size = 0
                guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                    parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
                    let pointer, size > 0, size <= ReceiverProtocol.maximumFrame else { throw HostError("Invalid H.264 parameter set.") }
                data.appendUInt32(UInt32(size)); data.append(pointer, count: size)
            }
        }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0, length + data.count <= ReceiverProtocol.maximumFrame else { throw HostError("H.264 frame is too large.") }
        var picture = Data(count: length)
        let copied = picture.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
        guard copied == noErr else { throw HostError("Could not read encoded H.264 bytes.") }
        data.append(picture)
        return data
    }
    private func send(_ sample: CMSampleBuffer) throws {
        let payload = try Self.avcc(sample)
        let packet = try ReceiverProtocol.packet(payload)
        wireQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.socket.writeAll(packet)
                let ack = try ReceiverAck(data: self.socket.readExactly(16))
                self.queue.async {
                    guard !self.stopped else { return }
                    let previous = self.statistics.receiver
                    guard ack.received == UInt32(truncatingIfNeeded: self.statistics.framesSent + 1),
                          ack.errors >= (previous?.errors ?? 0), ack.enqueued >= (previous?.enqueued ?? 0) else {
                        self.fail(HostError("The companion returned inconsistent frame counters.")); return
                    }
                    self.statistics.framesSent += 1; self.statistics.bytesSent += payload.count
                    self.statistics.receiver = ack
                    self.statistics.elapsedSeconds = ProcessInfo.processInfo.systemUptime - self.started
                    self.busy = false
                    // Congestion can make the receiver discard dependent frames; recover immediately.
                    if ack.enqueued == (previous?.enqueued ?? 0) { self.forceKeyframe = true }
                    if ack.errors > 10 { self.fail(HostError("The iPad reported repeated rendering errors.")); return }
                    if self.statistics.framesSent == 1 || self.statistics.elapsedSeconds - self.lastReport >= 1 {
                        self.lastReport = self.statistics.elapsedSeconds
                        self.report(self.statistics)
                    }
                    // Encode the most recent pending RAW frame as soon as the ACK arrives.
                    // Waiting for another capture tick needlessly halves the rate when a
                    // round trip takes just over one frame interval.
                    if self.imageRevision != self.encodingRevision { self.encodeLatest() }
                }
            } catch { self.queue.async { if !self.stopped { self.fail(error) } } }
        }
    }
    private func fail(_ error: Error) {
        guard !stopped else { return }
        stopped = true; socket.cancel(); failure(error)
    }
    func stop() async -> SessionStatistics {
        return await withCheckedContinuation { continuation in
            queue.async {
                self.stopped = true
                self.socket.cancel()
                self.timer?.cancel(); self.timer = nil; self.latestImage = nil
                if let encoder = self.encoder { VTCompressionSessionInvalidate(encoder); self.encoder = nil }
                self.statistics.elapsedSeconds = ProcessInfo.processInfo.systemUptime - self.started
                continuation.resume(returning: self.statistics)
            }
        }
    }
}

/// A moving pattern exercises the same encoder and USB path without recording a screen.
final class TestPattern {
    private var timer: DispatchSourceTimer?
    private var frame = 0
    init(pipeline: VideoPipeline, width: Int, height: Int, fps: Int) {
        let timer = DispatchSource.makeTimerSource(queue: pipeline.queue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / fps))
        timer.setEventHandler { [weak self, weak pipeline] in
            guard let self, let pipeline else { return }
            var buffer: CVPixelBuffer?
            let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
            guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs, &buffer) == kCVReturnSuccess, let buffer else { return }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let stride = CVPixelBufferGetBytesPerRow(buffer) / 4
                let pixels = base.assumingMemoryBound(to: UInt32.self)
                let colors: [UInt32] = [0xffe7e7e7, 0xffe3ce36, 0xff30c6d7, 0xff46b887, 0xffaa66cc, 0xffdd6056, 0xff426fcd, 0xff202632]
                let bar = (self.frame * 14) % width
                for y in 0..<height {
                    for x in 0..<width {
                        let grid = y % 80 < 2 || x % 80 < 2
                        pixels[y * stride + x] = abs(x - bar) < 12 ? 0xffffffff : (grid ? 0xff101722 : colors[min(7, x * 8 / width)])
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            self.frame += 1
            pipeline.offer(buffer)
        }
        self.timer = timer; timer.resume()
    }
    func stop() { timer?.cancel(); timer = nil }
    deinit { stop() }
}
