import Foundation

/// The private line between the running app and `Clips2 --mcp` (the MCP server Claude starts):
/// a Unix socket at ~/Library/Application Support/Clips 2/control.sock, one JSON object per line each way.
///   request  {"id":1,"method":"project_inspect","params":{…}}
///   reply    {"id":1,"ok":true,"result":…}   or   {"id":1,"ok":false,"error":"…"}

struct ControlError: Error, CustomStringConvertible {
    let description: String
    init(_ s: String) { description = s }
}

func unixAddress(_ path: String) -> sockaddr_un? {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    let cap = MemoryLayout.size(ofValue: addr.sun_path)
    guard bytes.count < cap else { return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        for (i, b) in bytes.enumerated() { buf[i] = b }
        buf[bytes.count] = 0
    }
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    return addr
}

@discardableResult
func writeAll(_ fd: Int32, _ d: Data) -> Bool {
    d.withUnsafeBytes { raw -> Bool in
        guard var p = raw.baseAddress else { return true }
        var left = raw.count
        while left > 0 {
            let n = Darwin.write(fd, p, left)
            if n < 0 { if errno == EINTR { continue }; return false }
            p = p.advanced(by: n); left -= n
        }
        return true
    }
}

/// Reads newline-separated messages from a file descriptor.
final class LineReader {
    let fd: Int32
    private var buf = Data()
    init(fd: Int32) { self.fd = fd }
    func next() -> Data? {
        while true {
            if let i = buf.firstIndex(of: 0x0A) {
                let line = Data(buf[buf.startIndex..<i])
                buf = Data(buf[(i + 1)...])
                if line.isEmpty || line == Data([0x0D]) { continue }
                return line
            }
            var tmp = [UInt8](repeating: 0, count: 65536)
            let n = Darwin.read(fd, &tmp, tmp.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 {
                if buf.isEmpty { return nil }
                let rest = buf; buf = Data(); return rest
            }
            buf.append(contentsOf: tmp[0..<n])
        }
    }
}

func jsonLine(_ d: [String: Any]) -> Data {
    if JSONSerialization.isValidJSONObject(d), let data = try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys, .withoutEscapingSlashes]) {
        return data
    }
    return Data("{\"ok\":false,\"error\":\"Winnow couldn't turn its answer into JSON.\"}".utf8)
}

private final class ControlRequest: @unchecked Sendable {
    var method = ""
    var params: Any? = nil
    var reply: [String: Any] = [:]
}

final class ControlServer: @unchecked Sendable {
    static let shared = ControlServer()
    static var socketPath: String { Store.supportDir.appendingPathComponent("control.sock").path }
    private var fd: Int32 = -1

    func start() {
        guard fd < 0 else { return }
        let path = Self.socketPath
        unlink(path)
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { Log.write("control: socket() failed \(errno)"); return }
        guard var addr = unixAddress(path) else { Log.write("control: path too long"); Darwin.close(s); return }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0, listen(s, 8) == 0 else { Log.write("control: bind/listen failed \(errno)"); Darwin.close(s); return }
        chmod(path, 0o600)
        fd = s
        Log.write("control: listening on \(path)")
        Thread.detachNewThread {
            while true {
                let c = Darwin.accept(s, nil, nil)
                if c < 0 { if errno == EINTR { continue }; break }
                Thread.detachNewThread { ControlServer.serve(c) }
            }
        }
    }

    func stop() {
        guard fd >= 0 else { return }
        Darwin.close(fd); fd = -1
        unlink(Self.socketPath)
    }

    private static func serve(_ c: Int32) {
        var on: Int32 = 1
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let reader = LineReader(fd: c)
        while let line = reader.next() {
            if !writeAll(c, respond(line) + Data([0x0A])) { break }
        }
        Darwin.close(c)
    }

    private static func respond(_ line: Data) -> Data {
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            return jsonLine(["ok": false, "error": "That request wasn't valid JSON."])
        }
        let req = ControlRequest()
        req.method = obj["method"] as? String ?? ""
        req.params = obj["params"]
        let sem = DispatchSemaphore(value: 0)
        Task { @MainActor in
            Background.lastRequest = Date()
            req.reply = await Control.handle(req.method, req.params)
            Background.lastRequest = Date()
            sem.signal()
        }
        sem.wait()
        var r = req.reply
        r["id"] = obj["id"] ?? NSNull()
        return jsonLine(r)
    }
}

/// The MCP side's way in: connect (starting Winnow in the background, with no window, if it isn't running),
/// send one request, read the reply.
enum ControlClient {
    static func connectOnce() -> Int32? {
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return nil }
        guard var addr = unixAddress(ControlServer.socketPath) else { Darwin.close(s); return nil }
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if r != 0 { Darwin.close(s); return nil }
        return s
    }

    static func connect() throws -> Int32 {
        if let s = connectOnce() { return s }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-g", "-b", "com.samuelroys.clips2", "--args", "--background"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
        for _ in 0..<100 {
            usleep(200_000)
            if let s = connectOnce() { return s }
        }
        throw ControlError("Winnow isn't running and didn't start. Open Winnow on the Mac and try again.")
    }

    static func request(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        let s = try connect()
        defer { Darwin.close(s) }
        var on: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 170, tv_usec: 0)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let req: [String: Any] = ["id": 1, "method": method, "params": params]
        guard JSONSerialization.isValidJSONObject(req) else { throw ControlError("Those parameters couldn't be sent.") }
        let d = try JSONSerialization.data(withJSONObject: req)
        guard writeAll(s, d + Data([0x0A])) else { throw ControlError("Lost the connection to Winnow.") }
        guard let line = LineReader(fd: s).next(),
              let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            throw ControlError("Winnow didn't answer in time (it may be busy).")
        }
        return obj
    }
}
