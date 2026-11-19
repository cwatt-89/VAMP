import CoreGraphics
import Foundation

/// Minimal RFB 3.8 client for QEMU's local VNC console: raw + CopyRect pixels, desktop resize,
/// and QEMU's extended key events (raw PC scancodes, so the guest's keyboard layout decides characters).
final class VNCClient {
    private let sock: UnixSocket
    private let fbLock = NSLock()
    private var width = 0
    private var height = 0
    private var fb: UnsafeMutablePointer<UInt8>?
    private(set) var extendedKeys = false

    /// Delivered on the main queue after each completed framebuffer update.
    var onFrame: ((CGImage) -> Void)?
    var onClose: (() -> Void)?

    private init(_ s: UnixSocket) { sock = s }

    static func connect(path: String, timeout: TimeInterval) async throws -> VNCClient {
        let c = VNCClient(try await UnixSocket.connect(path: path, timeout: timeout))
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global().async {
                do { try c.handshake(); cont.resume() } catch { cont.resume(throwing: error) }
            }
        }
        let t = Thread { c.readLoop() }
        t.name = "vnc-reader"
        t.start()
        return c
    }

    deinit { fb?.deallocate() }

    func close() { sock.shutdown() }

    // MARK: Handshake

    private func handshake() throws {
        guard let ver = sock.readBytes(12), String(decoding: ver, as: UTF8.self).hasPrefix("RFB ") else { throw FVError("Not a VNC server") }
        sock.write(Data("RFB 003.008\n".utf8))
        guard let n = sock.readBytes(1)?.first else { throw FVError("VNC closed during handshake") }
        if n == 0 { throw FVError("VNC refused connection") }
        guard let types = sock.readBytes(Int(n)), types.contains(1) else { throw FVError("VNC requires authentication") }
        sock.write(Data([1]))
        guard let result = sock.readBytes(4), result == [0, 0, 0, 0] else { throw FVError("VNC security handshake failed") }
        sock.write(Data([1])) // ClientInit, shared
        guard let si = sock.readBytes(24) else { throw FVError("VNC ServerInit missing") }
        let w = Int(si[0]) << 8 | Int(si[1]), h = Int(si[2]) << 8 | Int(si[3])
        let nameLen = Int(si[20]) << 24 | Int(si[21]) << 16 | Int(si[22]) << 8 | Int(si[23])
        _ = sock.readBytes(nameLen)
        resize(w, h)

        // 32bpp little-endian BGRX: maps straight onto CGImage byteOrder32Little + noneSkipFirst.
        var pf = Data([0, 0, 0, 0])
        pf += [32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0]
        sock.write(pf)
        let encodings: [Int32] = [1, 0, -223, -258] // CopyRect, Raw, DesktopSize, QEMU ExtendedKeyEvent
        var enc = Data([2, 0])
        enc += be16(encodings.count)
        for e in encodings { enc += be32(UInt32(bitPattern: e)) }
        sock.write(enc)
        request(incremental: false)
    }

    private func resize(_ w: Int, _ h: Int) {
        fbLock.lock()
        fb?.deallocate()
        width = max(1, w)
        height = max(1, h)
        fb = .allocate(capacity: width * height * 4)
        fb!.initialize(repeating: 0, count: width * height * 4)
        fbLock.unlock()
    }

    private func request(incremental: Bool) {
        var d = Data([3, incremental ? 1 : 0])
        d += be16(0) + be16(0) + be16(width) + be16(height)
        sock.write(d)
    }

    // MARK: Server messages

    private func readLoop() {
        loop: while let type = sock.readBytes(1)?.first {
            switch type {
            case 0:
                if !readUpdate() { break loop }
            case 1: // SetColourMapEntries
                guard let h = sock.readBytes(5) else { break loop }
                let n = Int(h[3]) << 8 | Int(h[4])
                _ = sock.readBytes(n * 6)
            case 2:
                continue // bell
            case 3: // ServerCutText
                guard let h = sock.readBytes(7) else { break loop }
                let len = Int(h[3]) << 24 | Int(h[4]) << 16 | Int(h[5]) << 8 | Int(h[6])
                _ = sock.readBytes(len)
            default:
                break loop // unknown message: can't resync
            }
        }
        DispatchQueue.main.async { self.onClose?() }
    }

    private func readUpdate() -> Bool {
        guard let h = sock.readBytes(3) else { return false }
        let rects = Int(h[1]) << 8 | Int(h[2])
        for _ in 0..<rects {
            guard let r = sock.readBytes(12) else { return false }
            let x = Int(r[0]) << 8 | Int(r[1]), y = Int(r[2]) << 8 | Int(r[3])
            let w = Int(r[4]) << 8 | Int(r[5]), hh = Int(r[6]) << 8 | Int(r[7])
            let enc = Int32(bitPattern: UInt32(r[8]) << 24 | UInt32(r[9]) << 16 | UInt32(r[10]) << 8 | UInt32(r[11]))
            switch enc {
            case 0:
                if !readRaw(x, y, w, hh) { return false }
            case 1:
                guard let s = sock.readBytes(4) else { return false }
                copyRect(sx: Int(s[0]) << 8 | Int(s[1]), sy: Int(s[2]) << 8 | Int(s[3]), x, y, w, hh)
            case -223:
                resize(w, hh)
            case -258:
                extendedKeys = true
            default:
                return false // unrequested encoding: can't skip its payload safely
            }
        }
        publish()
        request(incremental: true)
        return true
    }

    private func readRaw(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> Bool {
        let rowBytes = w * 4
        var scratch = [UInt8](repeating: 0, count: rowBytes)
        for row in 0..<h {
            guard scratch.withUnsafeMutableBytes({ sock.readExact($0.baseAddress!, rowBytes) }) else { return false }
            fbLock.lock()
            if let fb, x + w <= width, y + row < height {
                scratch.withUnsafeBytes { src in
                    (fb + ((y + row) * width + x) * 4).update(from: src.bindMemory(to: UInt8.self).baseAddress!, count: rowBytes)
                }
            }
            fbLock.unlock()
        }
        return true
    }

    private func copyRect(sx: Int, sy: Int, _ x: Int, _ y: Int, _ w: Int, _ h: Int) {
        fbLock.lock()
        defer { fbLock.unlock() }
        guard let fb, sx + w <= width, sy + h <= height, x + w <= width, y + h <= height else { return }
        let rowBytes = w * 4
        var tmp = [UInt8](repeating: 0, count: rowBytes * h)
        for r in 0..<h { tmp.withUnsafeMutableBytes { memcpy($0.baseAddress! + r * rowBytes, fb + ((sy + r) * width + sx) * 4, rowBytes) } }
        for r in 0..<h { tmp.withUnsafeBytes { _ = memcpy(fb + ((y + r) * width + x) * 4, $0.baseAddress! + r * rowBytes, rowBytes) } }
    }

    private func publish() {
        fbLock.lock()
        guard let fb else { fbLock.unlock(); return }
        let data = Data(bytes: fb, count: width * height * 4)
        let w = width, h = height
        fbLock.unlock()
        guard let provider = CGDataProvider(data: data as CFData),
              let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return }
        DispatchQueue.main.async { self.onFrame?(img) }
    }

    // MARK: Client input

    /// `qnum` is QEMU's key number: PC set-1 scancode, with 0x80 set for E0-prefixed keys.
    func key(qnum: UInt32, down: Bool) {
        var d = Data([255, 0])
        d += be16(down ? 1 : 0) + be32(0) + be32(qnum)
        sock.write(d)
    }

    /// Absolute pointer in framebuffer pixels. Buttons: 1 left, 2 middle, 4 right, 8/16 wheel up/down.
    func pointer(x: Int, y: Int, buttons: UInt8) {
        var d = Data([5, buttons])
        d += be16(min(max(0, x), width - 1)) + be16(min(max(0, y), height - 1))
        sock.write(d)
    }

    var size: (Int, Int) { (width, height) }

    private func be16(_ v: Int) -> Data { Data([UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]) }
    private func be32(_ v: UInt32) -> Data { Data([UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]) }
}

/// macOS virtual key codes → QEMU qnum (PC scancodes).
enum KeyMap {
    static let qnum: [UInt16: UInt32] = [
        0x00: 0x1E, 0x01: 0x1F, 0x02: 0x20, 0x03: 0x21, 0x04: 0x23, 0x05: 0x22, 0x06: 0x2C, 0x07: 0x2D,
        0x08: 0x2E, 0x09: 0x2F, 0x0A: 0x56, 0x0B: 0x30, 0x0C: 0x10, 0x0D: 0x11, 0x0E: 0x12, 0x0F: 0x13,
        0x10: 0x15, 0x11: 0x14, 0x12: 0x02, 0x13: 0x03, 0x14: 0x04, 0x15: 0x05, 0x16: 0x07, 0x17: 0x06,
        0x18: 0x0D, 0x19: 0x0A, 0x1A: 0x08, 0x1B: 0x0C, 0x1C: 0x09, 0x1D: 0x0B, 0x1E: 0x1B, 0x1F: 0x18,
        0x20: 0x16, 0x21: 0x1A, 0x22: 0x17, 0x23: 0x19, 0x24: 0x1C, 0x25: 0x26, 0x26: 0x24, 0x27: 0x28,
        0x28: 0x25, 0x29: 0x27, 0x2A: 0x2B, 0x2B: 0x33, 0x2C: 0x35, 0x2D: 0x31, 0x2E: 0x32, 0x2F: 0x34,
        0x30: 0x0F, 0x31: 0x39, 0x32: 0x29, 0x33: 0x0E, 0x35: 0x01,
        0x36: 0xDC, 0x37: 0xDB, 0x38: 0x2A, 0x39: 0x3A, 0x3A: 0x38, 0x3B: 0x1D, 0x3C: 0x36, 0x3D: 0xB8, 0x3E: 0x9D,
        0x41: 0x53, 0x43: 0x37, 0x45: 0x4E, 0x47: 0x45, 0x4B: 0xB5, 0x4C: 0x9C, 0x4E: 0x4A, 0x51: 0x59,
        0x52: 0x52, 0x53: 0x4F, 0x54: 0x50, 0x55: 0x51, 0x56: 0x4B, 0x57: 0x4C, 0x58: 0x4D, 0x59: 0x47,
        0x5B: 0x48, 0x5C: 0x49,
        0x60: 0x3F, 0x61: 0x40, 0x62: 0x41, 0x63: 0x3D, 0x64: 0x42, 0x65: 0x43, 0x67: 0x57, 0x69: 0xB7,
        0x6B: 0x46, 0x6D: 0x44, 0x6F: 0x58, 0x71: 0xC6, 0x72: 0xD2, 0x73: 0xC7, 0x74: 0xC9, 0x75: 0xD3,
        0x76: 0x3E, 0x77: 0xCF, 0x78: 0x3C, 0x79: 0xD1, 0x7A: 0x3B, 0x7B: 0xCB, 0x7C: 0xCD, 0x7D: 0xD0, 0x7E: 0xC8,
    ]

    static let leftShift: UInt32 = 0x2A

    /// US-layout characters → (qnum, shift), for "Type Clipboard".
    static let typing: [Character: (UInt32, Bool)] = {
        var m: [Character: (UInt32, Bool)] = [:]
        let rows: [(String, String, [UInt32])] = [
            ("`1234567890-=", "~!@#$%^&*()_+", [0x29, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D]),
            ("qwertyuiop[]\\", "QWERTYUIOP{}|", [0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x2B]),
            ("asdfghjkl;'", "ASDFGHJKL:\"", [0x1E, 0x1F, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28]),
            ("zxcvbnm,./", "ZXCVBNM<>?", [0x2C, 0x2D, 0x2E, 0x2F, 0x30, 0x31, 0x32, 0x33, 0x34, 0x35]),
        ]
        for (plain, shifted, codes) in rows {
            for (i, ch) in plain.enumerated() { m[ch] = (codes[i], false) }
            for (i, ch) in shifted.enumerated() { m[ch] = (codes[i], true) }
        }
        m[" "] = (0x39, false)
        m["\n"] = (0x1C, false)
        m["\t"] = (0x0F, false)
        return m
    }()
}
