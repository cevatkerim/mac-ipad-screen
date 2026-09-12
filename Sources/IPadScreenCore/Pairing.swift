import Foundation

public enum IPadModel: String, Codable, CaseIterable, Identifiable {
    case pro105, pro97, ipad9
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .pro105: return "iPad Pro 10.5-inch"
        case .pro97: return "iPad Pro 9.7-inch"
        case .ipad9: return "iPad (9th generation)"
        }
    }
    public var width: Int { switch self { case .pro105: return 2224; case .pro97: return 2048; case .ipad9: return 2160 } }
    public var height: Int { width * 3 / 4 }
    public static func detect(_ machine: String) -> Self? {
        switch machine {
        case "iPad7,3", "iPad7,4": return .pro105
        case "iPad6,3", "iPad6,4": return .pro97
        case "iPad12,1", "iPad12,2": return .ipad9
        default: return nil
        }
    }
}

public struct DeviceProfile: Codable, Equatable {
    public let udid: String
    public let key: String
    public var model: IPadModel
    public let tokenFile: String
    enum CodingKeys: String, CodingKey { case udid, key, model; case tokenFile = "token_file" }
    public init(udid: String, key: String, model: IPadModel, tokenFile: String) {
        self.udid = udid; self.key = key; self.model = model; self.tokenFile = tokenFile
    }
}

public final class StateStore {
    public let root: URL
    public init(root: URL) throws {
        self.root = root.standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    public func profiles() throws -> [String: DeviceProfile] {
        let file = root.appendingPathComponent("devices.json")
        if !FileManager.default.fileExists(atPath: file.path) { return [:] }
        return try JSONDecoder().decode([String: DeviceProfile].self, from: Data(contentsOf: file))
    }
    public func activeProfile() throws -> DeviceProfile? {
        let file = root.appendingPathComponent("device.json")
        if !FileManager.default.fileExists(atPath: file.path) { return nil }
        return try JSONDecoder().decode(DeviceProfile.self, from: Data(contentsOf: file))
    }
    public func save(_ profile: DeviceProfile, token: String? = nil) throws {
        try validate(profile)
        var all = try profiles()
        if let old = try activeProfile() { all[old.udid] = old }
        all[profile.udid] = profile
        if let token {
            _ = try ReceiverProtocol.hello(token: token)
            try writePrivate(Data((token + "\n").utf8), name: profile.tokenFile)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writePrivate(encoder.encode(all), name: "devices.json")
        try writePrivate(encoder.encode(profile), name: "device.json")
    }
    public func token(for profile: DeviceProfile) throws -> String {
        try validate(profile)
        let token = try String(contentsOf: root.appendingPathComponent(profile.tokenFile), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try ReceiverProtocol.hello(token: token)
        return token
    }
    public func writePrivate(_ data: Data, name: String) throws {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { throw HostError("Invalid state filename.") }
        // Atomic replacement inherits the restrictive directory; explicitly keep files private.
        let temporary = root.appendingPathComponent(".write-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw HostError("Could not write local pairing state.")
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary)
        guard rename(temporary.path, root.appendingPathComponent(name).path) == 0 else { throw HostError("Could not save local pairing state.") }
    }
    private func validate(_ profile: DeviceProfile) throws {
        guard !profile.udid.isEmpty, profile.udid.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) || $0 == 45 }),
              !profile.tokenFile.isEmpty, !profile.tokenFile.contains("/"), ![".", ".."].contains(profile.tokenFile) else {
            throw HostError("Invalid saved device profile.")
        }
    }
}

public enum SSH {
    public static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    public static var executable: String { Bundle.main.executableURL!.path }

    static func run(_ executable: String, arguments: [String], environment: [String: String]? = nil, timeout: TimeInterval = 25) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment ?? ProcessInfo.processInfo.environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        defer { deadline.cancel() }
        // Fixed setup commands produce small output; drain stderr concurrently.
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { _ = errors.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        group.wait()
        guard process.terminationStatus == 0 else {
            throw HostError("SSH setup failed. Check the mobile password, unlock the iPad, and ensure its jailbreak SSH server is running.")
        }
        return data
    }
    static func arguments(profile: DeviceProfile, store: StateStore, password: Bool) -> [String] {
        ["-F", "/dev/null", "-i", profile.key, "-o", "IdentitiesOnly=yes", "-o", "ConnectTimeout=8",
         "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2", "-o", "StrictHostKeyChecking=accept-new",
         "-o", "UserKnownHostsFile=\(store.root.appendingPathComponent("known_hosts").path)",
         "-o", "HostKeyAlias=ipad-\(profile.udid)",
         "-o", "ProxyCommand=" + [executable, "--usbmux-proxy", profile.udid].map(quote).joined(separator: " "),
         "-o", "BatchMode=\(password ? "no" : "yes")", "-o", "NumberOfPasswordPrompts=1", "mobile@ipad-usb"]
    }
    public static func command(_ command: String, profile: DeviceProfile, store: StateStore) throws -> Data {
        try run("/usr/bin/ssh", arguments: arguments(profile: profile, store: store, password: false) + [command])
    }
    public static func pair(device: USBDevice, model: IPadModel, password: String, keyPath: String?, store: StateStore) throws -> DeviceProfile {
        let key = keyPath.flatMap { $0.isEmpty ? nil : ($0 as NSString).expandingTildeInPath } ?? store.root.appendingPathComponent("mac-host-key").path
        if !FileManager.default.fileExists(atPath: key) {
            guard keyPath == nil || keyPath == "" else { throw HostError("The selected SSH private key does not exist.") }
            _ = try run("/usr/bin/ssh-keygen", arguments: ["-q", "-t", "ed25519", "-N", "", "-C", "ipad-screen-mac", "-f", key])
        }
        var profile = DeviceProfile(udid: device.id, key: key, model: model, tokenFile: "receiver-token-" + device.id)
        if !password.isEmpty {
            let publicKey = try String(contentsOfFile: key + ".pub", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !publicKey.contains("\n"), ["ssh-ed25519 ", "ssh-rsa ", "ecdsa-sha2-"].contains(where: publicKey.hasPrefix) else {
                throw HostError("Expected one OpenSSH public key.")
            }
            let secretName = ".askpass-" + UUID().uuidString
            try store.writePrivate(Data(password.utf8), name: secretName)
            defer { try? FileManager.default.removeItem(at: store.root.appendingPathComponent(secretName)) }
            var environment = ProcessInfo.processInfo.environment
            environment["SSH_ASKPASS"] = executable
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["DISPLAY"] = "ipad-screen:0"
            environment["IPAD_SCREEN_ASKPASS_FILE"] = store.root.appendingPathComponent(secretName).path
            let install = "set -eu; umask 077; mkdir -p \"$HOME/.ssh\"; chmod 700 \"$HOME/.ssh\"; touch \"$HOME/.ssh/authorized_keys\"; chmod 600 \"$HOME/.ssh/authorized_keys\"; key=\(quote(publicKey)); grep -qxF \"$key\" \"$HOME/.ssh/authorized_keys\" || printf '%s\\n' \"$key\" >> \"$HOME/.ssh/authorized_keys\""
            _ = try run("/usr/bin/ssh", arguments: arguments(profile: profile, store: store, password: true) + [install], environment: environment)
        }
        let response = try command("uname -m; cat /var/mobile/Library/Preferences/ipad-screen-token", profile: profile, store: store)
        let lines = String(decoding: response, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
        guard lines.count == 2 else { throw HostError("The installed companion token could not be read. Install the iPad Screen companion first.") }
        guard let detected = IPadModel.detect(lines[0]) else { throw HostError("This iPad model is not supported by the current display profiles.") }
        profile.model = detected
        try store.save(profile, token: lines[1])
        return profile
    }
    public static func launch(profile: DeviceProfile, store: StateStore) throws {
        _ = try command("/var/jb/usr/bin/uiopen --bundleid me.kerim.ipad-screen", profile: profile, store: store)
    }
}
