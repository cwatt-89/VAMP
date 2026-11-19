import AppKit
import Foundation

/// Dev aid: `VAMP --guest-script <vnc.sock> <script> <outdir>` drives a running guest over a second,
/// shared VNC connection (the app's own console stays attached). One command per line:
///   shot <name>        save the screen to <outdir>/<name>.png
///   type <text>        type text (US layout)
///   key <a+b+...>      press a chord: win ctrl shift alt enter esc tab space up down left right f1…, or a letter
///   click <x> <y>      left-click at framebuffer pixel
///   wait <seconds>
@MainActor
enum GuestDriver {
    static let named: [String: UInt32] = [
        "win": 0xDB, "ctrl": 0x1D, "shift": 0x2A, "alt": 0x38, "enter": 0x1C, "esc": 0x01, "tab": 0x0F,
        "space": 0x39, "up": 0xC8, "down": 0xD0, "left": 0xCB, "right": 0xCD, "backspace": 0x0E, "delete": 0xD3,
        "f1": 0x3B, "f2": 0x3C, "f3": 0x3D, "f4": 0x3E, "f5": 0x3F, "f10": 0x44,
    ]

    static func run(sock: String, script: String, outDir: String) async {
        guard let text = try? String(contentsOfFile: script, encoding: .utf8) else { print("no script"); return }
        let vnc: VNCClient
        do { vnc = try await VNCClient.connect(path: sock, timeout: 5) } catch { print("connect: \(error)"); return }
        var frame: CGImage?
        vnc.onFrame = { frame = $0 }
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        try? await Task.sleep(for: .seconds(1.5))

        func press(_ codes: [UInt32]) async {
            for c in codes { vnc.key(qnum: c, down: true); try? await Task.sleep(for: .milliseconds(30)) }
            for c in codes.reversed() { vnc.key(qnum: c, down: false); try? await Task.sleep(for: .milliseconds(30)) }
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            let arg = parts.count > 1 ? parts[1] : ""
            switch parts[0] {
            case "shot":
                try? await Task.sleep(for: .milliseconds(600))
                if let f = frame, let png = NSBitmapImageRep(cgImage: f).representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: "\(outDir)/\(arg).png"))
                    print("shot \(arg)")
                } else { print("shot \(arg): no frame") }
            case "type":
                for ch in arg {
                    guard let (code, shift) = KeyMap.typing[ch] else { print("untypable: \(ch)"); continue }
                    await press(shift ? [KeyMap.leftShift, code] : [code])
                }
            case "key":
                var codes: [UInt32] = []
                for k in arg.split(separator: "+").map({ String($0).lowercased() }) {
                    if let c = named[k] { codes.append(c) } else if let ch = k.first, let (c, _) = KeyMap.typing[ch] { codes.append(c) }
                }
                await press(codes)
            case "click":
                let xy = arg.split(separator: " ").compactMap { Int($0) }
                guard xy.count == 2 else { continue }
                vnc.pointer(x: xy[0], y: xy[1], buttons: 0)
                try? await Task.sleep(for: .milliseconds(80))
                vnc.pointer(x: xy[0], y: xy[1], buttons: 1)
                try? await Task.sleep(for: .milliseconds(80))
                vnc.pointer(x: xy[0], y: xy[1], buttons: 0)
            case "wait":
                try? await Task.sleep(for: .seconds(Double(arg) ?? 1))
            default:
                print("unknown: \(line)")
            }
        }
        vnc.close()
    }
}
