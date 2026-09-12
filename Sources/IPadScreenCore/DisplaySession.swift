import AppKit
import ScreenCaptureKit
import VirtualDisplay

public enum DisplayMode: String, CaseIterable { case extend, mirror, test }

public struct SessionOptions {
    public var mode: DisplayMode = .extend
    public var displayID: CGDirectDisplayID?
    public var fps = 30
    public var bitrate = 28_000_000
    public var retina = true
    public init() {}
}

@MainActor public final class DisplaySession: NSObject, SCStreamDelegate {
    public private(set) var isRunning = false
    public private(set) var virtualDisplayID: CGDirectDisplayID?
    private var virtualDisplay: IPDVirtualDisplay?
    private var pipeline: VideoPipeline?
    private var stream: SCStream?
    private var pattern: TestPattern?
    private var monitor: Task<Void, Never>?
    private var lockFile: Int32 = -1
    private var active = false
    private var stopping = false
    private let backgroundColor = CGColor(gray: 0, alpha: 1)
    private let store: StateStore
    private let report: (SessionStatistics) -> Void
    private let failure: (Error) -> Void
    public static var canExtend: Bool { IPDVirtualDisplay.isSupported() }

    public init(store: StateStore, report: @escaping (SessionStatistics) -> Void, failure: @escaping (Error) -> Void) {
        self.store = store; self.report = report; self.failure = failure
        super.init()
    }
    public func start(profile: DeviceProfile, options: SessionOptions) async throws {
        guard !active, !stopping else { throw HostError("A display session is already active.") }
        guard [30, 60].contains(options.fps), (4_000_000...80_000_000).contains(options.bitrate) else { throw HostError("Invalid frame rate or bitrate.") }
        active = true
        do {
            lockFile = open(store.root.appendingPathComponent("screen.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            guard lockFile >= 0, flock(lockFile, LOCK_EX | LOCK_NB) == 0 else { throw HostError("Another iPad Screen session is running. Stop it first.") }
            if options.mode != .test && !CGPreflightScreenCaptureAccess() {
                CGRequestScreenCaptureAccess()
                throw HostError("Allow iPad Screen in System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen this app.")
            }
            let token = try store.token(for: profile)
            let connection = try await Task.detached { [store] in
                // A manually foregrounded companion can stream even if SSH launch is unavailable.
                try? SSH.launch(profile: profile, store: store)
                for attempt in 0..<12 {
                    do { return try USBMux.receiver(deviceID: profile.udid, token: token) }
                    catch { if attempt == 11 { throw error }; try await Task.sleep(nanoseconds: 250_000_000) }
                }
                throw HostError("The companion did not start.")
            }.value
            guard active else { connection.cancel(); throw CancellationError() }
            let width = profile.model.width, height = profile.model.height
            let pipeline = try VideoPipeline(socket: connection, width: width, height: height, fps: options.fps,
                bitrate: options.bitrate, mode: options.mode.rawValue,
                report: { [weak self] value in Task { @MainActor in self?.report(value) } },
                failure: { [weak self] error in Task { @MainActor in await self?.failed(error) } })
            self.pipeline = pipeline
            if options.mode == .test {
                pattern = TestPattern(pipeline: pipeline, width: width, height: height, fps: options.fps)
            } else {
                let target: CGDirectDisplayID
                if options.mode == .extend {
                    // Stable per-device identity avoids accumulating ColorSync profiles.
                    let serial = profile.udid.utf8.reduce(UInt32(2166136261)) { ($0 ^ UInt32($1)) &* 16777619 }
                    virtualDisplay = try IPDVirtualDisplay(width: UInt32(width), height: UInt32(height), refreshRate: Double(options.fps), retina: options.retina, serial: serial)
                    guard let id = virtualDisplay?.displayID, id != 0 else { throw HostError("macOS did not create a virtual display.") }
                    virtualDisplayID = id; target = id
                } else { target = options.displayID ?? CGMainDisplayID() }
                var selected: SCDisplay?
                for _ in 0..<20 {
                    guard active else { throw CancellationError() }
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    selected = content.displays.first { $0.displayID == target }
                    if selected != nil { break }
                    try await Task.sleep(nanoseconds: 150_000_000)
                }
                guard active else { throw CancellationError() }
                guard let selected else { throw HostError("The selected display is no longer available.") }
                // Virtual display registration is asynchronous. Configure its origin only
                // after WindowServer has published it to ScreenCaptureKit.
                try virtualDisplay?.positionToRight()
                let filter = SCContentFilter(display: selected, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = width; config.height = height
                config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(options.fps))
                config.queueDepth = 3; config.showsCursor = true; config.capturesAudio = false
                config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                config.colorSpaceName = CGColorSpace.itur_709
                config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
                config.preservesAspectRatio = true; config.scalesToFit = true
                config.backgroundColor = backgroundColor
                config.streamName = "iPad Screen"
                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                self.stream = stream
                try stream.addStreamOutput(pipeline, type: .screen, sampleHandlerQueue: pipeline.queue)
                try await stream.startCapture()
                guard active else { try? await stream.stopCapture(); throw CancellationError() }
                monitor = Task { [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
                        guard let self, self.active else { return }
                        if CGDisplayIsActive(target) == 0 { await self.failed(HostError("The captured display was removed.")); return }
                    }
                }
            }
            pipeline.startHeartbeat()
            isRunning = true
        } catch { _ = await stop(); throw error }
    }
    public func stop() async -> SessionStatistics? {
        guard !stopping else { return nil }
        stopping = true; active = false; isRunning = false
        monitor?.cancel(); monitor = nil
        pattern?.stop(); pattern = nil
        let stats = await pipeline?.stop()
        pipeline = nil
        let previous = stream; stream = nil
        try? await previous?.stopCapture()
        virtualDisplay = nil; virtualDisplayID = nil
        if lockFile >= 0 { close(lockFile); lockFile = -1 }
        if let stats, let data = try? JSONEncoder().encode(stats) { try? store.writePrivate(data, name: "mac-session.json") }
        stopping = false
        return stats
    }
    private func failed(_ error: Error) async {
        guard active else { return }
        _ = await stop()
        failure(error)
    }
    nonisolated public func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in await self?.failed(error) }
    }
}
