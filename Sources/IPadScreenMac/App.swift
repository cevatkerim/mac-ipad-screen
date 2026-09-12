import SwiftUI
import AppKit
import IPadScreenCore

@MainActor final class HostModel: ObservableObject {
    static let shared = HostModel()
    @Published var devices: [USBDevice] = []
    @Published var selectedID = ""
    @Published var profiles: [String: DeviceProfile] = [:]
    @Published var displayID = CGMainDisplayID()
    @Published var screens: [NSScreen] = []
    @Published var fps = 30
    @Published var retina = true
    @Published var bitrate = 28
    @Published var encoderMode: EncoderMode = .hardware
    @Published var status = "Connect your iPad with a USB cable."
    @Published var error: String?
    @Published var busy = false
    @Published var running = false
    @Published var statistics = SessionStatistics()
    @Published var mode: DisplayMode?
    @Published var showPairing = false
    let store: StateStore
    private var session: DisplaySession?
    private var operation: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var sleepObserver: NSObjectProtocol?
    var profile: DeviceProfile? { profiles[selectedID] }
    var selectedDevice: USBDevice? { devices.first { $0.id == selectedID } }

    init() {
        do { store = try StateStore(root: stateRoot()) }
        catch { fatalError("Could not open iPad Screen state: \(error.localizedDescription)") }
        do { profiles = try store.profiles(); selectedID = try store.activeProfile()?.udid ?? "" }
        catch { self.error = error.localizedDescription }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.stop() }
        }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }
    func refresh() async {
        guard !busy else { return }
        screens = NSScreen.screens.filter { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) != session?.virtualDisplayID }
        do {
            let found = try await Task.detached { try USBMux.devices() }.value
            devices = found
            if selectedID.isEmpty, found.count == 1 { selectedID = found[0].id }
            if !running && error == nil {
                if selectedDevice == nil { status = "Connect and unlock your paired iPad." }
                else if profile == nil { status = "iPad connected. Pair it with this Mac to begin." }
                else { status = "\(profile!.model.label) is ready over USB." }
            }
        } catch { if !running { status = error.localizedDescription } }
    }
    func pair(password: String, keyPath: String) {
        guard let device = selectedDevice, !busy else { return }
        busy = true; error = nil; status = "Pairing with your iPad…"
        operation = Task {
            defer { busy = false; operation = nil }
            do {
                let paired = try await Task.detached { [store] in
                    try SSH.pair(device: device, model: .pro105, password: password, keyPath: keyPath.isEmpty ? nil : keyPath, store: store)
                }.value
                profiles = try store.profiles(); selectedID = paired.udid
                showPairing = false; status = "\(paired.model.label) is ready over USB."
            } catch { self.error = error.localizedDescription; status = "Pairing needs attention." }
        }
    }
    func start(_ mode: DisplayMode) {
        guard !busy, !running, let profile else { return }
        busy = true; error = nil; self.mode = mode; statistics = SessionStatistics()
        status = "\(mode == .extend ? "Extending" : mode == .mirror ? "Mirroring" : "Testing") your display…"
        operation = Task {
            defer { busy = false; operation = nil }
            do {
                try store.save(profile)
                let session = DisplaySession(store: store, report: { [weak self] stats in self?.statistics = stats }, failure: { [weak self] error in
                    self?.running = false; self?.error = error.localizedDescription; self?.status = "Session stopped."; self?.session = nil
                })
                self.session = session
                var options = SessionOptions(); options.mode = mode; options.displayID = displayID
                options.fps = fps; options.bitrate = bitrate * 1_000_000; options.retina = retina
                options.encoderMode = encoderMode
                try await session.start(profile: profile, options: options)
                running = true
                status = mode == .extend ? "Your iPad is a second display. Move a window to the right." : mode == .mirror ? "Your Mac display is mirrored to the iPad." : "A moving test pattern is streaming to the iPad."
            } catch is CancellationError { status = "Stopped." }
            catch { self.error = error.localizedDescription; status = "Could not start the display."; self.session = nil }
        }
    }
    func stop() async {
        operation?.cancel()
        if let stats = await session?.stop() { statistics = stats }
        await operation?.value
        session = nil; running = false; mode = nil; status = "Stopped. Your iPad is ready to reconnect."
    }
    func openRecordingSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
}

struct IPadScreenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = HostModel.shared
    var body: some Scene {
        Window("iPad Screen", id: "main") {
            HostView(model: model)
        }
        .defaultSize(width: 580, height: 740)
        .windowResizability(.contentSize)
        MenuBarExtra("iPad Screen", systemImage: model.running ? "display.2" : "ipad.landscape") {
            MenuControls(model: model)
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.activate(ignoringOtherApps: true) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { await HostModel.shared.stop(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

struct MenuControls: View {
    @ObservedObject var model: HostModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(model.running ? "Connected over USB" : "iPad Screen")
        Button("Show iPad Screen") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Divider()
        Button("Extend Desktop") { model.start(.extend) }.disabled(model.busy || model.running || model.profile == nil || model.selectedDevice == nil)
        Button("Mirror Display") { model.start(.mirror) }.disabled(model.busy || model.running || model.profile == nil || model.selectedDevice == nil)
        Button("Stop") { Task { await model.stop() } }.disabled(!model.running && !model.busy)
        Divider()
        Button("Quit iPad Screen") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

struct HostView: View {
    @ObservedObject var model: HostModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16).fill(Color.accentColor.gradient).frame(width: 64, height: 64)
                    Image(systemName: "display.2").font(.system(size: 30, weight: .medium)).foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("iPad Screen").font(.largeTitle.weight(.semibold))
                    Text("More room for your Mac.").foregroundStyle(.secondary)
                }
                Spacer()
                Label("USB", systemImage: "cable.connector").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Circle().fill(model.running ? Color.green : model.selectedDevice != nil ? Color.blue : Color.gray).frame(width: 8, height: 8)
                        Text(model.running ? "Connected" : model.selectedDevice != nil ? "USB connected" : "Waiting for iPad").font(.headline)
                        Spacer()
                        if model.busy { ProgressView().controlSize(.small) }
                        else { Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("Refresh USB devices") }
                    }
                    Picker("iPad", selection: $model.selectedID) {
                        Text("Select a device").tag("")
                        ForEach(Array(model.devices.enumerated()), id: \.element.id) { index, device in
                            Text(model.profiles[device.id]?.model.label ?? "USB device \(index + 1)").tag(device.id)
                        }
                    }.disabled(model.running || model.busy)
                    if let profile = model.profile {
                        Text("\(String(profile.model.width)) × \(String(profile.model.height)) · Native resolution").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text(model.profile == nil ? "Pair once to use the installed companion." : "Paired with this Mac.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(model.profile == nil ? "Pair iPad…" : "Pairing…") { model.error = nil; model.showPairing = true }
                            .disabled(model.selectedDevice == nil || model.running || model.busy)
                    }
                }.padding(8)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Mirror source", selection: $model.displayID) {
                        ForEach(model.screens, id: \.self) { screen in
                            Text(screen.localizedName).tag((screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) ?? 0)
                        }
                    }
                    HStack {
                        Picker("Frame rate", selection: $model.fps) { Text("30 fps").tag(30); Text("60 fps").tag(60) }.frame(maxWidth: 260)
                        Spacer()
                        Toggle("Retina extension", isOn: $model.retina)
                    }
                    Picker("Encoder", selection: $model.encoderMode) {
                        ForEach(EncoderMode.allCases) { mode in Text(mode.label).tag(mode) }
                    }
                    HStack {
                        Text("Quality").frame(width: 80, alignment: .leading)
                        Slider(value: Binding(get: { Double(model.bitrate) }, set: { model.bitrate = Int($0) }), in: 8...60, step: 2)
                        Text("\(model.bitrate) Mbps").monospacedDigit().frame(width: 70, alignment: .trailing)
                    }
                }.padding(8).disabled(model.running || model.busy)
            }
            HStack(spacing: 12) {
                Button { model.start(.extend) } label: { Label("Extend Desktop", systemImage: "display.2").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).disabled(model.running || model.busy || model.profile == nil || model.selectedDevice == nil || !DisplaySession.canExtend)
                Button { model.start(.mirror) } label: { Label("Mirror Display", systemImage: "rectangle.on.rectangle").frame(maxWidth: .infinity) }
                    .disabled(model.running || model.busy || model.profile == nil || model.selectedDevice == nil)
            }.controlSize(.large)
            VStack(alignment: .leading, spacing: 10) {
                Text(model.status).font(.callout).fixedSize(horizontal: false, vertical: true)
                if model.statistics.framesSent > 0 {
                    HStack(spacing: 20) {
                        Label("\(model.statistics.receiver?.enqueued ?? 0) queued", systemImage: "film")
                        Text(String(format: "%.1f fps avg", model.statistics.averageFPS))
                        Text("\(model.statistics.receiver?.errors ?? 0) errors")
                    }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text(String(format: "%@ · encode %.1f ms · USB + ack %.1f ms",
                        model.statistics.hardwareEncoder ? "Hardware H.264" : "Software H.264",
                        model.statistics.averageEncodeMilliseconds, model.statistics.averageUSBMilliseconds))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = model.error {
                    Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    if error.contains("Recording") || error.contains("recording") {
                        Button("Open Screen Recording Settings") { model.openRecordingSettings() }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            HStack {
                Menu("More") {
                    Button("Test Receiver") { model.start(.test) }.disabled(model.busy || model.running || model.profile == nil || model.selectedDevice == nil)
                    Button("Screen Recording Settings") { model.openRecordingSettings() }
                    Button("Display Arrangement") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!) }
                }.fixedSize()
                Spacer()
                if model.running || model.busy { Button("Stop") { Task { await model.stop() } }.keyboardShortcut(".", modifiers: .command) }
                Text("Keyboard & mouse stay on Mac").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(28).frame(width: 580)
        .sheet(isPresented: $model.showPairing) { PairingView(model: model) }
    }
}

struct PairingView: View {
    @ObservedObject var model: HostModel
    @State private var password = ""
    @State private var keyPath = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Pair this iPad").font(.title2.weight(.semibold))
            Text("Keep the iPad unlocked. Enter the mobile SSH password used by its jailbreak. Your installed iPad Screen companion will open automatically.").foregroundStyle(.secondary)
            SecureField("Mobile SSH password", text: $password)
            DisclosureGroup("Use an existing SSH key") {
                TextField("Private key path (optional)", text: $keyPath).padding(.top, 8)
                Text("An already authorized key can be used without a password.").font(.caption).foregroundStyle(.secondary)
            }
            Text("A dedicated Mac key is added while preserving existing keys. The password is discarded after pairing.").font(.caption).foregroundStyle(.secondary)
            if let error = model.error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { model.showPairing = false }.disabled(model.busy)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("Pair iPad") { model.pair(password: password, keyPath: keyPath); password = "" }
                    .buttonStyle(.borderedProminent).disabled(model.busy).keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width: 430).interactiveDismissDisabled(model.busy)
    }
}
