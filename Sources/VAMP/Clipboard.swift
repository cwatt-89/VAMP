import AppKit
import Foundation

/// VAMP's own guest channel: a virtio-serial port ("org.vamp.clipboard") that QEMU exposes on a Unix
/// socket, spoken by the VAMP Tools agent inside the guest. Frames both ways: [u32 LE type][u32 LE length][payload].
final class GuestChannel {
    enum Kind: UInt32 { case text = 1, png = 2, time = 3, hello = 16, ready = 17 }
    static let portName = "org.vamp.clipboard"
    static let maxPayload = 64 << 20

    private let sock: UnixSocket
    private let writeQueue = DispatchQueue(label: "vamp.guest-channel.write")
    private let pendingLock = NSLock()
    private var pendingClipboard: Data?

    /// Delivered on the main queue.
    var onMessage: ((Kind, Data) -> Void)?
    var onClose: (() -> Void)?

    private init(_ s: UnixSocket) { sock = s }

    static func connect(path: String, timeout: TimeInterval) async throws -> GuestChannel {
        let c = GuestChannel(try await UnixSocket.connect(path: path, timeout: timeout))
        let t = Thread { c.readLoop() }
        t.name = "vamp-guest-channel"
        t.start()
        return c
    }

    func close() { sock.shutdown() }

    static func frame(_ kind: Kind, _ payload: Data) -> Data {
        var d = Data(capacity: 8 + payload.count)
        withUnsafeBytes(of: kind.rawValue.littleEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { d.append(contentsOf: $0) }
        d.append(payload)
        return d
    }

    func sendHello() { let f = Self.frame(.hello, Data()); writeQueue.async { self.sock.write(f) } }

    /// The Mac's clock (ms since 1970 UTC). Sent when the agent connects and after the Mac wakes.
    func sendTime() {
        let ms = Int64(Date().timeIntervalSince1970 * 1000)
        var d = Data()
        withUnsafeBytes(of: ms.littleEndian) { d.append(contentsOf: $0) }
        let f = Self.frame(.time, d)
        writeQueue.async { self.sock.write(f) }
    }

    /// Clipboard contents: only the newest is kept while a slow write is in flight, so stale copies never pile up.
    func sendClipboard(_ kind: Kind, _ payload: Data) {
        guard payload.count <= Self.maxPayload else { return }
        pendingLock.lock()
        let wasIdle = pendingClipboard == nil
        pendingClipboard = Self.frame(kind, payload)
        pendingLock.unlock()
        guard wasIdle else { return }
        writeQueue.async {
            self.pendingLock.lock()
            let f = self.pendingClipboard
            self.pendingClipboard = nil
            self.pendingLock.unlock()
            if let f { self.sock.write(f) }
        }
    }

    private func readLoop() {
        while let h = sock.readBytes(8) {
            let type = UInt32(h[0]) | UInt32(h[1]) << 8 | UInt32(h[2]) << 16 | UInt32(h[3]) << 24
            let len = Int(UInt32(h[4]) | UInt32(h[5]) << 8 | UInt32(h[6]) << 16 | UInt32(h[7]) << 24)
            guard let kind = Kind(rawValue: type), len <= Self.maxPayload, let body = sock.readBytes(len) else { break }
            let data = Data(body)
            DispatchQueue.main.async { self.onMessage?(kind, data) }
        }
        DispatchQueue.main.async { self.onClose?() }
    }
}

/// Keeps the Mac pasteboard and one VM's clipboard in step (text and images) through VAMP Tools.
@MainActor
final class ClipboardSync {
    private let channel: GuestChannel
    private var lastChange = NSPasteboard.general.changeCount
    private var timer: Timer?
    private(set) var guestReady = false
    var enabled: () -> Bool
    var onReadyChange: ((Bool) -> Void)?

    init(channel: GuestChannel, enabled: @escaping () -> Bool) {
        self.channel = channel
        self.enabled = enabled
        channel.onMessage = { [weak self] kind, data in MainActor.assumeIsolated { self?.received(kind, data) } }
        channel.sendHello()
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        // A sleeping Mac pauses the VM's clock: put the guest's clock right once the Mac is awake again.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { MainActor.assumeIsolated { if self?.guestReady == true { self?.channel.sendTime() } } }
        }
    }

    private var wakeObserver: NSObjectProtocol?

    func stop() {
        if let o = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        wakeObserver = nil
        timer?.invalidate()
        timer = nil
        channel.close()
    }

    private func received(_ kind: GuestChannel.Kind, _ data: Data) {
        switch kind {
        case .ready:
            let first = !guestReady
            guestReady = true
            if first { onReadyChange?(true) }
            channel.sendTime()
            // The agent just (re)started: hand it whatever the Mac has now, so the first paste in the VM works.
            if enabled() { pushMac() }
        case .text:
            guard enabled(), let s = String(data: data, encoding: .utf8) else { return }
            let pb = NSPasteboard.general
            if pb.string(forType: .string) == s { return }
            pb.clearContents()
            pb.setString(s, forType: .string)
            lastChange = pb.changeCount
        case .png:
            guard enabled(), NSBitmapImageRep(data: data) != nil else { return }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setData(data, forType: .png)
            if let tiff = NSImage(data: data)?.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
            lastChange = pb.changeCount
        case .hello, .time:
            break
        }
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        if enabled() && guestReady { pushMac() }
    }

    private func pushMac() {
        let pb = NSPasteboard.general
        let types = pb.types ?? []
        // Skip what other apps mark as not-for-sharing housekeeping (e.g. clipboard managers' own writes).
        if types.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) { return }
        if let s = pb.string(forType: .string) {
            channel.sendClipboard(.text, Data(s.utf8))
        } else if let png = ClipboardSync.png(from: pb) {
            channel.sendClipboard(.png, png)
        }
    }

    static func png(from pb: NSPasteboard) -> Data? {
        if let d = pb.data(forType: .png) { return d }
        guard let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
