import AppKit
import SwiftUI
import IPadScreenCore
import VirtualDisplay

let arguments = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}

func stateRoot() -> URL {
    if let path = option("--state-dir") ?? ProcessInfo.processInfo.environment["IPAD_SCREEN_STATE_DIR"] {
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }
    var directory = Bundle.main.executableURL!.deletingLastPathComponent()
    for _ in 0..<8 {
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path),
           FileManager.default.fileExists(atPath: directory.appendingPathComponent("Sources/IPadScreenMac").path) {
            return directory.appendingPathComponent(".runtime")
        }
        directory.deleteLastPathComponent()
    }
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("iPad Screen/.runtime")
}

func printError(_ error: Error) {
    FileHandle.standardError.write(Data(("iPad Screen: \(error.localizedDescription)\n").utf8))
}

if let secret = ProcessInfo.processInfo.environment["IPAD_SCREEN_ASKPASS_FILE"] {
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: secret))
        try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
        exit(0)
    } catch { exit(1) }
} else if let device = option("--usbmux-proxy") {
    do { try USBMux.relay(deviceID: device); exit(0) }
    catch { printError(error); exit(1) }
} else if arguments.contains("--help") {
    print("""
    iPad Screen — native macOS USB host
    Open the app with no arguments for the graphical controls.

    --diagnose                        Report USB, pairing, and capture access
    --pair [--key-file PATH]           Import token using an authorized SSH key
    --run extend|mirror|test           Stream to the selected paired iPad
      --seconds N                     Stop after N seconds (default: until Ctrl+C)
      --fps 30|60                     Requested frame rate (default: 30)
      --bitrate-mbps N                4–80 Mbps (default: 28)
      --encoder hardware|low-latency  Hardware saves CPU; low latency favors speed
      --display-id N                  Existing Mac display to mirror
      --standard-scale               Use 1× instead of Retina in extend mode
    --check-virtual                    Create/remove a temporary display and verify cleanup
    --state-dir PATH                   Override local pairing state directory
    """)
    exit(0)
} else if arguments.contains(where: { ["--run", "--diagnose", "--pair", "--check-virtual"].contains($0) }) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    Task { @MainActor in
        do { try await runCLI(); exit(0) }
        catch { printError(error); exit(1) }
    }
    app.run()
} else {
    IPadScreenApp.main()
}

@MainActor func runCLI() async throws {
    let store = try StateStore(root: stateRoot())
    if arguments.contains("--diagnose") {
        let devices = try await Task.detached { try USBMux.devices() }.value
        let paired = try store.activeProfile()
        print("USB devices: \(devices.count)")
        print("Selected iPad: \(paired?.model.label ?? "not paired")")
        print("Selected device connected: \(devices.contains { $0.id == paired?.udid })")
        print("Screen recording allowed: \(CGPreflightScreenCaptureAccess())")
        print("Virtual display backend available: \(DisplaySession.canExtend)")
        for screen in NSScreen.screens {
            print("Mac display: \(screen.localizedName), \(Int(screen.frame.width))×\(Int(screen.frame.height)) points")
        }
        return
    }
    if arguments.contains("--check-virtual") {
        func activeIDs() -> Set<CGDirectDisplayID> {
            var ids = [CGDirectDisplayID](repeating: 0, count: 64), count: UInt32 = 0
            CGGetActiveDisplayList(64, &ids, &count)
            return Set(ids.prefix(Int(count)))
        }
        let before = activeIDs()
        var display: IPDVirtualDisplay? = try IPDVirtualDisplay(width: 2048, height: 1536, refreshRate: 30, retina: true, serial: 0x49504454)
        let id = display!.displayID
        try await Task.sleep(nanoseconds: 500_000_000)
        guard activeIDs().contains(id), let mode = CGDisplayCopyDisplayMode(id) else { throw HostError("Virtual display did not become active.") }
        try display?.positionToRight()
        let retina = mode.pixelWidth == 2048 && mode.pixelHeight == 1536 && mode.width == 1024 && mode.height == 768
        print("Virtual display: \(mode.pixelWidth)×\(mode.pixelHeight) pixels, \(mode.width)×\(mode.height) points")
        display = nil
        for _ in 0..<20 {
            if activeIDs() == before { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard activeIDs() == before else { throw HostError("Virtual display cleanup did not restore the previous display set.") }
        guard retina else { throw HostError("macOS did not apply the requested Retina mode.") }
        print("Virtual display creation, Retina mode, and removal verified.")
        return
    }
    if arguments.contains("--pair") {
        let devices = try await Task.detached { try USBMux.devices() }.value
        let saved = try store.activeProfile()
        guard let device = devices.first(where: { $0.id == saved?.udid }) ?? (devices.count == 1 ? devices.first : nil) else {
            throw HostError("Select a USB iPad in the app before pairing.")
        }
        let key = option("--key-file") ?? saved?.key
        let paired = try await Task.detached {
            try SSH.pair(device: device, model: .pro105, password: "", keyPath: key, store: store)
        }.value
        print("Paired \(paired.model.label); existing companion token verified.")
        return
    }
    guard let modeString = option("--run"), let mode = DisplayMode(rawValue: modeString) else { throw HostError("Use --run extend, mirror, or test.") }
    guard let profile = try store.activeProfile() else { throw HostError("Pair your iPad using the graphical app first.") }
    var options = SessionOptions(); options.mode = mode
    if let value = option("--encoder") {
        guard let encoder = EncoderMode(rawValue: value) else { throw HostError("Use --encoder hardware or low-latency.") }
        options.encoderMode = encoder
    }
    if let value = option("--fps") { guard let fps = Int(value), [30,60].contains(fps) else { throw HostError("Use --fps 30 or 60.") }; options.fps = fps }
    if let value = option("--bitrate-mbps") { guard let rate = Int(value), (4...80).contains(rate) else { throw HostError("Use a bitrate from 4 to 80 Mbps.") }; options.bitrate = rate * 1_000_000 }
    if let value = option("--display-id") { guard let id = UInt32(value) else { throw HostError("Invalid display ID.") }; options.displayID = id }
    options.retina = !arguments.contains("--standard-scale")
    guard let seconds = Double(option("--seconds") ?? "0"), seconds.isFinite, (0...86400).contains(seconds) else { throw HostError("Seconds must be between 0 and 86400.") }
    var errorSeen: Error?
    var lastPrint = -5.0
    let session = DisplaySession(store: store, report: { stats in
        if stats.elapsedSeconds - lastPrint >= 5 {
            print("Sent/enqueued: \(stats.framesSent)/\(stats.receiver?.enqueued ?? 0); renderer errors: \(stats.receiver?.errors ?? 0); hardware H.264: \(stats.hardwareEncoder); encode/USB+ack: " + String(format: "%.1f/%.1f ms", stats.averageEncodeMilliseconds, stats.averageUSBMilliseconds))
            fflush(stdout); lastPrint = stats.elapsedSeconds
        }
    }, failure: { errorSeen = $0 })
    var interrupted = false
    var signals: [DispatchSourceSignal] = []
    for code in [SIGINT, SIGTERM] {
        signal(code, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: code, queue: .main)
        source.setEventHandler { interrupted = true; Task { _ = await session.stop() } }
        source.resume(); signals.append(source)
    }
    defer { signals.forEach { $0.cancel() } }
    try await session.start(profile: profile, options: options)
    print("Streaming \(mode.rawValue): \(profile.model.width)×\(profile.model.height), requested \(options.fps) fps. Ctrl+C stops.")
    fflush(stdout)
    let started = ProcessInfo.processInfo.systemUptime
    while !interrupted, errorSeen == nil, session.isRunning, seconds == 0 || ProcessInfo.processInfo.systemUptime - started < seconds {
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    if let stats = await session.stop() {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        print("Stopped: " + String(decoding: try encoder.encode(stats), as: UTF8.self))
        if !interrupted && stats.framesSent == 0 { throw HostError("No frames reached the iPad.") }
    }
    if let errorSeen { throw errorSeen }
}
