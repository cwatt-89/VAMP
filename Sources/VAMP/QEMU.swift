import Darwin
import Foundation

/// Paths to the external tools VAMP drives. QEMU does the device emulation and uses Apple's
/// Hypervisor.framework (HVF) for near-native ARM64 CPU speed; swtpm provides the TPM 2.0 Windows 11 wants.
struct QEMUTools: Equatable {
    var qemu: String?
    var img: String?
    var swtpm: String?
    var firmwareCode: String?
    var varsTemplate: String?

    var ready: Bool { qemu != nil && img != nil && firmwareCode != nil && varsTemplate != nil }

    static var prefixes: [String] {
        var p: [String] = []
        if let custom = UserDefaults.standard.string(forKey: "qemuPrefix"), !custom.isEmpty { p.append(custom) }
        if let res = Bundle.main.resourcePath { p.append(res + "/qemu") }
        return p + ["/opt/homebrew", "/usr/local", "/opt/local"]
    }

    static func locate() -> QEMUTools {
        let fm = FileManager.default
        func bin(_ name: String) -> String? {
            prefixes.map { "\($0)/bin/\(name)" }.first { fm.isExecutableFile(atPath: $0) }
        }
        func share(_ name: String) -> String? {
            prefixes.map { "\($0)/share/qemu/\(name)" }.first { fm.fileExists(atPath: $0) }
        }
        return QEMUTools(qemu: bin("qemu-system-aarch64"), img: bin("qemu-img"), swtpm: bin("swtpm"),
                         firmwareCode: share("edk2-aarch64-code.fd"), varsTemplate: share("edk2-arm-vars.fd"))
    }

    var missing: [String] {
        var m: [String] = []
        if qemu == nil || img == nil || firmwareCode == nil { m.append("qemu") }
        if swtpm == nil { m.append("swtpm") }
        return m
    }
}

/// Files inside a VM bundle (`<id>.vamp`) and the short runtime directory for its sockets.
/// Unix socket paths max out at 104 bytes, so sockets live under /tmp rather than Application Support.
struct VMPaths {
    let bundle: URL
    let id: UUID
    var config: URL { bundle.appendingPathComponent("config.json") }
    var disk: URL { bundle.appendingPathComponent("disk.qcow2") }
    var vars: URL { bundle.appendingPathComponent("efivars.qcow2") }
    var tpmDir: URL { bundle.appendingPathComponent("tpm") }
    var log: URL { bundle.appendingPathComponent("qemu.log") }
    var thumbnail: URL { bundle.appendingPathComponent("thumbnail.png") }
    /// Sockets dir. A VM still running from the FloydVM days keeps using /tmp/floydvm-<id> until it stops.
    var run: URL {
        let short = id.uuidString.prefix(8).lowercased()
        let legacy = URL(fileURLWithPath: "/tmp/floydvm-" + short)
        if FileManager.default.fileExists(atPath: legacy.appendingPathComponent("qemu.pid").path) { return legacy }
        return URL(fileURLWithPath: "/tmp/vamp-" + short)
    }
    var qmpSock: String { run.appendingPathComponent("qmp.sock").path }
    /// Second QMP socket for scripts (scripts/sandbox.sh), so they never fight the app for qmp.sock.
    var ctlSock: String { run.appendingPathComponent("ctl.sock").path }
    var vncSock: String { run.appendingPathComponent("vnc.sock").path }
    var tpmSock: String { run.appendingPathComponent("tpm.sock").path }
    /// VAMP Tools channel (shared clipboard), a virtio-serial port on the guest side.
    var clipSock: String { run.appendingPathComponent("clip.sock").path }
    var pidFile: String { run.appendingPathComponent("qemu.pid").path }
}

enum QEMUCommand {
    static let suspendTag = "vamp-suspend"

    /// QEMU option values treat "," as a separator; a literal comma is written ",,".
    static func esc(_ s: String) -> String { s.replacingOccurrences(of: ",", with: ",,") }

    static func arguments(_ c: VMConfig, paths p: VMPaths, tools t: QEMUTools, loadVM: String? = nil) -> [String] {
        var a: [String] = ["-name", esc(c.name)]
        a += ["-machine", "virt", "-accel", "hvf", "-cpu", "host", "-smp", "\(c.cpus)", "-m", "\(c.memoryMB)"]
        a += ["-drive", "if=pflash,format=raw,readonly=on,file=\(esc(t.firmwareCode ?? ""))"]
        a += ["-drive", "if=pflash,format=qcow2,file=\(esc(p.vars.path))"]

        // Every PCI device sits in a fixed slot, whatever else is configured. Windows identifies hardware
        // by slot, so a device that moves (e.g. when the display type changes) shows up as new hardware
        // ("Ethernet 2") and loses its settings. Slots match what existing installs already have.
        //   01 USB · 02 display · 03 NVMe · 04 network · 05 audio · 06 RNG · 07 guest channel
        // Input: USB keyboard + absolute tablet (no mouse grab needed).
        a += ["-device", "qemu-xhci,id=usb,addr=0x1", "-device", "usb-kbd,bus=usb.0", "-device", "usb-tablet,bus=usb.0"]

        switch c.display {
        case .ramfb: a += ["-device", "ramfb"]
        case .virtioGPU: a += ["-device", "virtio-gpu-pci,addr=0x2,xres=1920,yres=1080"] // widescreen; driver is on VAMP's built-in driver disc
        }

        // System disk on NVMe: Windows ships an inbox NVMe driver, so setup sees it without extra drivers.
        a += ["-drive", "if=none,id=hd0,file=\(esc(p.disk.path)),format=qcow2,discard=unmap,detect-zeroes=unmap",
              "-device", "nvme,drive=hd0,serial=FLOYDVM0,addr=0x3,bootindex=0"] // serial kept from FloydVM so existing Windows installs see the same disk

        // USB CD drives: installer, VAMP driver disc, setup disc. Explicit usb-bot + scsi-cd gives each a stable id
        // ("cdrom0"/"cdrom1") for live media changes over QMP.
        var cds = [c.isoPath, c.driversISOPath]
        if let s = c.setupISOPath, FileManager.default.fileExists(atPath: s) { cds.append(s) }
        for (i, iso) in cds.enumerated() {
            var drive = "if=none,id=cd\(i),media=cdrom,readonly=on"
            if let iso, !iso.isEmpty { drive += ",file=\(esc(iso)),format=raw" }
            // USB, not SATA: the ARM UEFI firmware has no AHCI driver, so it can't boot a SATA CD.
            a += ["-drive", drive, "-device", "usb-bot,id=usbcd\(i)",
                  "-device", "scsi-cd,bus=usbcd\(i).0,drive=cd\(i),id=cdrom\(i)" + (i == 0 ? ",bootindex=1" : "")] // disk first: an empty disk falls through to the installer, an installed one never waits on the CD
        }

        switch c.network {
        case .nat:
            var net = "user,id=net0"
            for f in c.portForwards { net += ",hostfwd=\(f.proto):127.0.0.1:\(f.hostPort)-:\(f.guestPort)" }
            a += ["-netdev", net, "-device", "virtio-net-pci,addr=0x4,netdev=net0,mac=\(c.macAddress)"]
        case .none:
            a += ["-nic", "none"]
        }

        if c.tpm {
            // ppi=off: the TPM Physical Presence page can't be mapped under HVF (HV_BAD_ARGUMENT).
            a += ["-chardev", "socket,id=chrtpm,path=\(p.tpmSock)", "-tpmdev", "emulator,id=tpm0,chardev=chrtpm",
                  "-device", "tpm-tis-device,tpmdev=tpm0,ppi=off"]
        }
        if c.sound {
            a += ["-audiodev", "coreaudio,id=snd0", "-device", "intel-hda,addr=0x5", "-device", "hda-output,audiodev=snd0"]
        }
        if c.os != .windows11 { a += ["-device", "virtio-rng-pci,addr=0x6"] }
        if c.guestChannel {
            // Shared clipboard: the VAMP Tools agent in the guest opens \\.\Global\org.vamp.clipboard; VAMP connects here.
            a += ["-device", "virtio-serial-pci,id=vser0,addr=0x7",
                  "-chardev", "socket,id=vampchan,path=\(p.clipSock),server=on,wait=off",
                  "-device", "virtserialport,bus=vser0.0,chardev=vampchan,name=\(GuestChannel.portName)"]
        }
        a += ["-rtc", c.os == .windows11 ? "base=localtime" : "base=utc"]

        a += ["-qmp", "unix:\(p.qmpSock),server=on,wait=off", "-qmp", "unix:\(p.ctlSock),server=on,wait=off", "-vnc", "unix:\(p.vncSock)",
              "-display", "none", "-monitor", "none", "-serial", "none", "-pidfile", p.pidFile]
        if let loadVM { a += ["-loadvm", loadVM] }
        a += c.extraArgs.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        return a
    }

    static func shellLine(_ exe: String, _ args: [String]) -> String {
        ([exe] + args).map { $0.contains(" ") || $0.contains(",,") ? "'\($0)'" : $0 }.joined(separator: " ")
    }
}

enum Shell {
    /// Runs a tool to completion off the main thread; returns exit status and combined output.
    static func run(_ exe: String, _ args: [String]) async -> (status: Int32, output: String) {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                do { try p.run() } catch {
                    cont.resume(returning: (-1, error.localizedDescription))
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: (p.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
        }
    }

    @discardableResult
    static func check(_ exe: String, _ args: [String]) async throws -> String {
        let r = await run(exe, args)
        if r.status != 0 {
            throw FVError("\((exe as NSString).lastPathComponent) failed: \(r.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return r.output
    }
}

enum DiskImage {
    static func create(_ tools: QEMUTools, paths: VMPaths, sizeGB: Int) async throws {
        guard let img = tools.img, let vars = tools.varsTemplate else { throw FVError("qemu-img not found. Install QEMU: brew install qemu") }
        try await Shell.check(img, ["create", "-q", "-f", "qcow2", paths.disk.path, "\(sizeGB)G"])
        // UEFI variable store as qcow2 (not raw) so internal snapshots (savevm) can include it.
        try await Shell.check(img, ["convert", "-q", "-f", "raw", "-O", "qcow2", vars, paths.vars.path])
    }

    struct Info { var virtual: Int64; var snapshots: [SnapshotInfo] }

    /// `-U` (force-share) reads metadata while QEMU holds the image lock.
    static func info(_ tools: QEMUTools, _ url: URL) async -> Info? {
        guard let img = tools.img else { return nil }
        let r = await Shell.run(img, ["info", "-U", "--output=json", url.path])
        guard r.status == 0, let obj = try? JSONSerialization.jsonObject(with: Data(r.output.utf8)) as? [String: Any] else { return nil }
        let snaps = (obj["snapshots"] as? [[String: Any]] ?? []).map { s in
            SnapshotInfo(name: s["name"] as? String ?? "?",
                         date: Date(timeIntervalSince1970: (s["date-sec"] as? Double) ?? 0),
                         vmClockSec: (s["vm-clock-sec"] as? Int) ?? 0,
                         vmStateSize: (s["vm-state-size"] as? NSNumber)?.int64Value ?? 0)
        }
        return Info(virtual: (obj["virtual-size"] as? NSNumber)?.int64Value ?? 0, snapshots: snaps)
    }
}

enum ProcStats {
    private static let timebase: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom)
    }()

    /// Total CPU time in nanoseconds and resident memory, or nil if the process is gone.
    static func sample(_ pid: pid_t) -> (cpuNs: Double, rss: Int64)? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        return (Double(info.pti_total_user + info.pti_total_system) * timebase, Int64(info.pti_resident_size))
    }

    static func name(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 1024)
        proc_name(pid, &buf, UInt32(buf.count))
        return String(cString: buf)
    }

    static func alive(_ pid: pid_t) -> Bool { pid > 0 && kill(pid, 0) == 0 }
}
