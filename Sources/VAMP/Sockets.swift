import Darwin
import Foundation

/// Blocking Unix-domain stream socket used by the QMP and VNC clients (each reads on its own thread).
final class UnixSocket {
    let fd: Int32
    private let writeLock = NSLock()

    init(path: String) throws {
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { throw FVError("socket() failed") }
        var on: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(s); throw FVError("socket path too long") }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(s, $0, len) } }
        guard r == 0 else { close(s); throw FVError("connect \(path): \(String(cString: strerror(errno)))") }
        fd = s
    }

    /// Retries until the socket accepts, the deadline passes, or `alive` says the server died.
    static func connect(path: String, timeout: TimeInterval, alive: @escaping () -> Bool = { true }) async throws -> UnixSocket {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let s = try? UnixSocket(path: path) { return s }
            if Date() > deadline { throw FVError("Timed out connecting to \((path as NSString).lastPathComponent)") }
            if !alive() { throw FVError("QEMU exited during startup") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    func write(_ data: Data) {
        writeLock.lock()
        defer { writeLock.unlock() }
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + off, raw.count - off)
                if n <= 0 { if errno == EINTR { continue }; return }
                off += n
            }
        }
    }

    /// Fills `count` bytes at `ptr`; false on EOF/error.
    func readExact(_ ptr: UnsafeMutableRawPointer, _ count: Int) -> Bool {
        var off = 0
        while off < count {
            let n = read(fd, ptr + off, count - off)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return false }
            off += n
        }
        return true
    }

    func readBytes(_ count: Int) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: count)
        if count == 0 { return buf }
        return buf.withUnsafeMutableBytes { readExact($0.baseAddress!, count) } ? buf : nil
    }

    func shutdown() { Darwin.shutdown(fd, SHUT_RDWR) }
    deinit { close(fd) }
}

// MARK: - QMP

/// QEMU Machine Protocol client: JSON commands over the control socket, plus async events.
final class QMPClient {
    private let sock: UnixSocket
    private let lock = NSLock()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Any, Error>] = [:]
    /// Delivered on the main queue.
    var onEvent: ((String, [String: Any]) -> Void)?
    var onClose: (() -> Void)?

    private init(_ s: UnixSocket) { sock = s }

    static func connect(path: String, timeout: TimeInterval, alive: @escaping () -> Bool) async throws -> QMPClient {
        let c = QMPClient(try await UnixSocket.connect(path: path, timeout: timeout, alive: alive))
        let t = Thread { c.readLoop() }
        t.name = "qmp-reader"
        t.start()
        _ = try await c.execute("qmp_capabilities")
        return c
    }

    @discardableResult
    func execute(_ cmd: String, _ args: [String: Any]? = nil) async throws -> Any {
        try await withCheckedThrowingContinuation { cont in
            lock.lock()
            let id = nextID
            nextID += 1
            pending[id] = cont
            lock.unlock()
            var msg: [String: Any] = ["execute": cmd, "id": id]
            if let args { msg["arguments"] = args }
            var data = (try? JSONSerialization.data(withJSONObject: msg)) ?? Data()
            data.append(0x0A)
            sock.write(data)
        }
    }

    /// Human monitor command (savevm/loadvm/delvm). Returns its text output; errors come back as text.
    func hmp(_ line: String) async throws -> String {
        let out = try await execute("human-monitor-command", ["command-line": line]) as? String ?? ""
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().contains("error") { throw FVError(trimmed) }
        return trimmed
    }

    func close() { sock.shutdown() }

    private func readLoop() {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(sock.fd, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer = Data(buffer[(nl + 1)...])
                handle(line)
            }
        }
        lock.lock()
        let waiting = pending
        pending.removeAll()
        lock.unlock()
        for c in waiting.values { c.resume(throwing: FVError("QEMU control connection closed")) }
        DispatchQueue.main.async { self.onClose?() }
    }

    private func handle(_ line: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        if let ev = obj["event"] as? String {
            let data = obj["data"] as? [String: Any] ?? [:]
            DispatchQueue.main.async { self.onEvent?(ev, data) }
            return
        }
        guard let id = obj["id"] as? Int else { return } // greeting
        lock.lock()
        let cont = pending.removeValue(forKey: id)
        lock.unlock()
        if let err = obj["error"] as? [String: Any] {
            cont?.resume(throwing: FVError(err["desc"] as? String ?? "QMP error"))
        } else {
            cont?.resume(returning: obj["return"] ?? [:])
        }
    }
}
