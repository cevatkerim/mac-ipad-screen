import Foundation
import Darwin

public struct HostError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

extension Data {
    func uint32(at offset: Int, bigEndian: Bool = true) -> UInt32 {
        let bytes = Array(self[offset..<(offset + 4)])
        return (bigEndian ? bytes : bytes.reversed()).reduce(0) { ($0 << 8) | UInt32($1) }
    }
    mutating func appendUInt32(_ number: UInt32, bigEndian: Bool = true) {
        var value = bigEndian ? number.bigEndian : number.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}

public enum ReceiverProtocol {
    public static let maximumFrame = 8 * 1024 * 1024
    public static func hello(token: String) throws -> Data {
        guard token.utf8.count == 64, token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw HostError("Invalid companion token. Pair this iPad again.")
        }
        return Data(("IPDS0001" + token).utf8)
    }
    public static func packet(_ avcc: Data) throws -> Data {
        guard !avcc.isEmpty, avcc.count <= maximumFrame else { throw HostError("Encoded frame exceeds protocol limits.") }
        var offset = 0
        while offset < avcc.count {
            guard avcc.count - offset >= 4 else { throw HostError("Truncated AVCC NAL header.") }
            let count = Int(avcc.uint32(at: offset))
            offset += 4
            guard count > 0, count <= avcc.count - offset else { throw HostError("Invalid AVCC NAL length.") }
            offset += count
        }
        var result = Data()
        result.appendUInt32(UInt32(avcc.count))
        result.append(avcc)
        return result
    }
}

public struct ReceiverAck: Codable, Equatable {
    public let received: UInt32
    public let enqueued: UInt32
    public let errors: UInt32
    public init(data: Data) throws {
        guard data.count == 16, data.uint32(at: 4) == 0 else { throw HostError("Invalid receiver acknowledgment.") }
        received = data.uint32(at: 0)
        enqueued = data.uint32(at: 8)
        errors = data.uint32(at: 12)
        guard enqueued <= received else { throw HostError("Invalid receiver frame counters.") }
    }
}

/// Blocking I/O is confined to worker queues. shutdown() cancels pending I/O;
/// the descriptor stays owned until deinit, avoiding descriptor reuse races.
public final class LocalSocket {
    let fd: Int32
    init(fd: Int32) throws {
        guard fd >= 0 else { throw HostError("Could not open the local USB socket.") }
        self.fd = fd
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        setTimeout(seconds: 5)
    }
    deinit { Darwin.close(fd) }
    public func cancel() { Darwin.shutdown(fd, SHUT_RDWR) }
    public func setTimeout(seconds: Int) {
        var value = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout.size(ofValue: value)))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout.size(ofValue: value)))
    }
    public func readExactly(_ count: Int) throws -> Data {
        guard count >= 0, count <= ReceiverProtocol.maximumFrame else { throw HostError("Invalid USB read size.") }
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < count {
                let received = Darwin.recv(fd, bytes.baseAddress!.advanced(by: offset), count - offset, 0)
                if received < 0 && errno == EINTR { continue }
                guard received > 0 else { throw HostError("The iPad disconnected or stopped responding. Unlock it and open iPad Screen.") }
                offset += received
            }
        }
        return data
    }
    public func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < data.count {
                let sent = Darwin.send(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset, 0)
                if sent < 0 && errno == EINTR { continue }
                guard sent > 0 else { throw HostError("The USB connection closed while sending a frame.") }
                offset += sent
            }
        }
    }
}

public struct USBDevice: Identifiable, Equatable {
    public let id: String
    public let muxID: Int
    public init(id: String, muxID: Int) { self.id = id; self.muxID = muxID }
}

public enum USBMux {
    static func socket() throws -> LocalSocket {
        let socket = try LocalSocket(fd: Darwin.socket(AF_UNIX, SOCK_STREAM, 0))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let path = Array("/var/run/usbmuxd".utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socket.fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { throw HostError("Cannot access macOS USB services. Connect and trust the iPad over USB.") }
        return socket
    }
    static func responseLength(header: Data) throws -> Int {
        guard header.count == 16 else { throw HostError("Truncated usbmux header.") }
        let count = Int(header.uint32(at: 0, bigEndian: false))
        guard (16...1_048_576).contains(count), header.uint32(at: 4, bigEndian: false) == 1,
              header.uint32(at: 8, bigEndian: false) == 8, header.uint32(at: 12, bigEndian: false) == 1 else {
            throw HostError("Invalid usbmux response header.")
        }
        return count - 16
    }
    static func request(_ socket: LocalSocket, _ fields: [String: Any]) throws -> [String: Any] {
        let values = fields.merging(["ClientVersionString": "ipad-screen-mac/0.1", "ProgName": "ipad-screen", "kLibUSBMuxVersion": 3]) { a, _ in a }
        let payload = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
        var header = Data()
        for value in [UInt32(payload.count + 16), 1, 8, 1] { header.appendUInt32(value, bigEndian: false) }
        try socket.writeAll(header + payload)
        let length = try responseLength(header: socket.readExactly(16))
        guard let reply = try PropertyListSerialization.propertyList(from: socket.readExactly(length), format: nil) as? [String: Any] else {
            throw HostError("Invalid usbmux property list.")
        }
        return reply
    }
    public static func devices() throws -> [USBDevice] {
        let reply = try request(socket(), ["MessageType": "ListDevices"])
        guard let list = reply["DeviceList"] as? [[String: Any]] else { throw HostError("macOS did not return a USB device list.") }
        return list.compactMap { entry in
            guard let props = entry["Properties"] as? [String: Any], props["ConnectionType"] as? String == "USB",
                  let id = props["SerialNumber"] as? String, let muxID = entry["DeviceID"] as? Int else { return nil }
            return USBDevice(id: id, muxID: muxID)
        }.sorted { $0.id < $1.id }
    }
    public static func connect(deviceID: String, port: UInt16) throws -> LocalSocket {
        guard let device = try devices().first(where: { $0.id == deviceID }) else { throw HostError("The selected USB iPad is not connected.") }
        let connection = try socket()
        let response = try request(connection, ["MessageType": "Connect", "DeviceID": device.muxID, "PortNumber": Int(port.bigEndian)])
        guard response["Number"] as? Int == 0 else { throw HostError("The iPad service is unavailable. Unlock it and open the companion app.") }
        return connection
    }
    public static func receiver(deviceID: String, token: String) throws -> LocalSocket {
        let hello = try ReceiverProtocol.hello(token: token)
        let connection = try connect(deviceID: deviceID, port: 27184)
        try connection.writeAll(hello)
        guard try connection.readExactly(8) == Data("READY001".utf8) else { throw HostError("Companion authentication failed. Pair the iPad again.") }
        return connection
    }
    public static func relay(deviceID: String, port: UInt16 = 22) throws {
        let socket = try connect(deviceID: deviceID, port: port)
        socket.setTimeout(seconds: 0)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            do {
                while true {
                    let data = FileHandle.standardInput.availableData
                    if data.isEmpty { break }
                    try socket.writeAll(data)
                }
                Darwin.shutdown(socket.fd, SHUT_WR)
            } catch { socket.cancel() }
        }
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = Darwin.recv(socket.fd, &buffer, buffer.count, 0)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { break }
            try FileHandle.standardOutput.write(contentsOf: Data(buffer.prefix(count)))
        }
        try FileHandle.standardOutput.close()
        group.wait()
    }
}
