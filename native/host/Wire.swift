import Foundation
import CryptoKit
import Darwin

typealias JSONObject = [String: Any]

enum BridgeError: LocalizedError {
    case disconnected
    case invalid
    case tooLarge
    case io
    case closed
    case wrongPeer
    case systemCall(String, Int32)

    var errorDescription: String? {
        switch self {
        case .disconnected: return "The companion is not running."
        case .invalid: return "The native playback message is invalid."
        case .tooLarge: return "The native playback message exceeds its size limit."
        case .io: return "The playback helper did not answer."
        case .closed: return "The companion closed the connection before the message was complete."
        case .wrongPeer: return "The companion and Safari extension have different signatures."
        case .systemCall(let operation, let code):
            return "\(operation) failed (\(code)): \(String(cString: strerror(code)))."
        }
    }
}

func reply(_ state: String, _ message: String) -> JSONObject {
    ["state": state, "message": message]
}

// The containing app and extension use a private binary protocol on IPv4 loopback.
// No HTTP or WebSocket endpoint is exposed. Each native peer authenticates the
// precise payload and direction using a per-build key compiled into both binaries.
enum Wire {
    static let port = UInt16(43_000 + geteuid() % 11_000)
    static let maxFrame = 12_288
    private static let key = SymmetricKey(data: signatureSeed)

    static func encode(_ object: JSONObject, direction: String, nonce: String) throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: object)
        let packet: JSONObject = ["nonce": nonce, "at": Date().timeIntervalSince1970, "body": body.base64EncodedString()]
        let content = try JSONSerialization.data(withJSONObject: packet)
        let signed = Data(direction.utf8) + content
        return Data(HMAC<SHA256>.authenticationCode(for: signed, using: key)) + content
    }

    static func decode(_ data: Data, direction: String) throws -> (JSONObject, String) {
        guard data.count > 32 && data.count <= maxFrame else { throw BridgeError.invalid }
        let tag = Data(data.prefix(32))
        let content = Data(data.dropFirst(32))
        guard HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: Data(direction.utf8) + content, using: key)
        else { throw BridgeError.wrongPeer }
        guard let packet = try JSONSerialization.jsonObject(with: content) as? JSONObject,
              let nonce = packet["nonce"] as? String, UUID(uuidString: nonce) != nil,
              let at = packet["at"] as? Double, abs(Date().timeIntervalSince1970 - at) < 30,
              let b64 = packet["body"] as? String, let body = Data(base64Encoded: b64),
              let obj = try JSONSerialization.jsonObject(with: body) as? JSONObject
        else { throw BridgeError.invalid }
        return (obj, nonce)
    }

    static func configure(_ fd: Int32) throws {
        // Darwin propagates O_NONBLOCK from the listener to an accepted socket.
        // readFrame deliberately uses blocking reads bounded by SO_RCVTIMEO.
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) == 0 else {
            throw BridgeError.systemCall("configure native socket", errno)
        }
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        var t = timeval(tv_sec: 2, tv_usec: 500_000)
        for opt in [SO_RCVTIMEO, SO_SNDTIMEO] {
            _ = setsockopt(fd, SOL_SOCKET, opt, &t, socklen_t(MemoryLayout.size(ofValue: t)))
        }
    }

    static func address() -> sockaddr_in {
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        return a
    }

    static func withAddress<T>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        var a = address()
        return withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
    }

    static func readBytes(_ fd: Int32, _ count: Int) throws -> Data {
        var bytes = Data(count: count)
        try bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { throw BridgeError.invalid }
            var offset = 0
            while offset < count {
                let n = Darwin.read(fd, base.advanced(by: offset), count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else {
                    if n == 0 { throw BridgeError.closed }
                    throw BridgeError.systemCall("read native message", errno)
                }
                offset += n
            }
        }
        return bytes
    }

    static func readFrame(_ fd: Int32) throws -> Data {
        let count = try readBytes(fd, 4).reduce(0) { ($0 << 8) | Int($1) }
        guard (1...maxFrame).contains(count) else { throw BridgeError.tooLarge }
        return try readBytes(fd, count)
    }

    static func writeBytes(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { throw BridgeError.invalid }
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else {
                    if n == 0 { throw BridgeError.closed }
                    throw BridgeError.systemCall("write native message", errno)
                }
                offset += n
            }
        }
    }

    static func writeFrame(_ fd: Int32, _ frame: Data) throws {
        guard !frame.isEmpty && frame.count <= maxFrame else { throw BridgeError.tooLarge }
        var count = UInt32(frame.count).bigEndian
        try withUnsafeBytes(of: &count) { try writeBytes(fd, Data($0)) }
        try writeBytes(fd, frame)
    }

    static func request(_ obj: JSONObject) throws -> JSONObject {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BridgeError.systemCall("create native socket", errno) }
        defer { close(fd) }
        try configure(fd)
        guard withAddress({ Darwin.connect(fd, $0, $1) }) == 0 else {
            let code = errno
            if code == ECONNREFUSED { throw BridgeError.disconnected }
            throw BridgeError.systemCall("connect to companion", code)
        }
        let nonce = UUID().uuidString
        try writeFrame(fd, encode(obj, direction: "request", nonce: nonce))
        let (answer, echo) = try decode(readFrame(fd), direction: "reply")
        guard echo == nonce else { throw BridgeError.invalid }
        return answer
    }

    static func validate(_ raw: JSONObject) -> JSONObject? {
        guard let op = raw["op"] as? String, ["sync", "stop", "status"].contains(op),
              let session = raw["session"] as? String,
              session.range(of: #"\A[A-Za-z0-9_-]{1,128}\z"#, options: .regularExpression) != nil else { return nil }
        var command: JSONObject = ["op": op, "session": session]
        if op == "sync" {
            guard let video = raw["videoId"] as? String,
                  video.range(of: #"\A[A-Za-z0-9_-]{11}\z"#, options: .regularExpression) != nil,
                  let t = raw["time"] as? Double, t.isFinite, (0...31_536_000).contains(t),
                  let rate = raw["rate"] as? Double, rate.isFinite, (0.1...16).contains(rate),
                  let volume = raw["volume"] as? Double, volume.isFinite, (0...1).contains(volume),
                  let playing = raw["playing"] as? Bool,
                  let muted = raw["muted"] as? Bool else { return nil }
            command.merge(["videoId": video, "time": t, "playing": playing, "rate": rate, "volume": volume, "muted": muted, "armed": raw["armed"] as? Bool ?? false]) { _, v in v }
        }
        return command
    }
}
