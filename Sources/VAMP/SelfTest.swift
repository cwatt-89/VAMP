import AppKit
import Foundation

/// `VAMP --selftest`: boots a real throwaway VM (UEFI only, no OS) in a temp folder and exercises
/// start, console frames, keys, pause/resume, live + offline snapshots, CD swap, suspend/resume and force off.
@MainActor
enum SelfTest {
    static func run() async -> Bool {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vamp-selftest-\(UUID().uuidString.prefix(6))")
        setenv("VAMP_ROOT", root.path, 1)
        defer { try? FileManager.default.removeItem(at: root) }
        var ok = true
        func check(_ name: String, _ cond: Bool, _ detail: String = "") {
            print((cond ? "PASS " : "FAIL ") + name + (detail.isEmpty ? "" : " — \(detail)"))
            if !cond { ok = false }
        }
        func wait(_ secs: Double, _ cond: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(secs)
            while Date() < end { if cond() { return true }; try? await Task.sleep(for: .milliseconds(100)) }
            return cond()
        }

        let lib = Library()
        check("tools located", lib.tools.ready && lib.tools.swtpm != nil, "\(lib.tools)")
        guard lib.tools.ready else { return false }

        var cfg = VMConfig(name: "SelfTest, VM", os: .windows11) // comma exercises QEMU escaping
        cfg.cpus = 2
        cfg.memoryMB = 1024
        cfg.sound = false
        let args = QEMUCommand.arguments(cfg, paths: VMPaths(bundle: root, id: cfg.id), tools: lib.tools)
        check("args: hvf + tpm + nvme", args.contains("hvf") && args.contains { $0.hasPrefix("tpm-tis-device") } && args.contains { $0.hasPrefix("nvme") })

        let vm: VM
        do { vm = try await lib.create(cfg, diskGB: 4) } catch { check("create VM", false, error.localizedDescription); return false }
        check("create VM", FileManager.default.fileExists(atPath: vm.paths.disk.path) && FileManager.default.fileExists(atPath: vm.paths.vars.path))
        check("RDP forward added", vm.config.rdpForward != nil)

        vm.start()
        check("starts", await wait(25) { vm.state == .running }, vm.lastError ?? "\(vm.state)")
        guard vm.state == .running else { print(vm.lastError ?? ""); return false }
        check("console frame with content", await wait(20) { frameHasContent(vm.lastFrame) }, "fb \(vm.fbSize)")
        vm.vnc?.key(qnum: 0x01, down: true)
        vm.vnc?.key(qnum: 0x01, down: false)
        vm.vnc?.pointer(x: 10, y: 10, buttons: 0)

        try? await Task.sleep(for: .seconds(1))
        let cpuSampled = await wait(5) { vm.rss > 0 }
        check("stats sampled", cpuSampled, "rss \(vm.rss)")

        vm.pause()
        check("pause", await wait(5) { vm.state == .paused })
        vm.resume()
        check("resume", await wait(5) { vm.state == .running })

        await vm.takeSnapshot("live one")
        let live = vm.snapshots.first { $0.name == "live-one" }
        check("live snapshot with memory", live != nil && live!.vmStateSize > 0, "\(vm.snapshots)")
        if let live { await vm.revert(to: live) }
        check("live revert", vm.lastError == nil && vm.state == .running, vm.lastError ?? "")

        vm.setMedia(slot: 1, path: lib.tools.varsTemplate)
        try? await Task.sleep(for: .milliseconds(500))
        check("swap CD live", vm.lastError == nil, vm.lastError ?? "")
        vm.setMedia(slot: 1, path: nil)
        try? await Task.sleep(for: .milliseconds(500))

        await vm.suspend()
        check("suspend", await wait(10) { vm.state == .stopped } && vm.config.suspended, vm.lastError ?? "")
        vm.start()
        check("resume from suspend", await wait(25) { vm.state == .running } && !vm.config.suspended, vm.lastError ?? "\(vm.state)")

        vm.forceOff()
        check("force off", await wait(10) { vm.state == .stopped })
        check("thumbnail saved", FileManager.default.fileExists(atPath: vm.paths.thumbnail.path))
        check("no unexpected error", vm.lastError == nil, vm.lastError ?? "")

        await vm.takeSnapshot("offline")
        let off = vm.snapshots.first { $0.name == "offline" }
        check("offline snapshot", off != nil && off!.vmStateSize == 0, "\(vm.snapshots)")
        if let off {
            await vm.revert(to: off)
            check("offline revert", vm.lastError == nil, vm.lastError ?? "")
            await vm.deleteSnapshot(off)
            check("delete snapshot", !vm.snapshots.contains { $0.name == "offline" })
        }

        await vm.growDisk(toGB: 6)
        check("grow disk", vm.diskVirtual == 6 * 1_073_741_824, "\(vm.diskVirtual)")

        lib.clone(vm)
        check("clone", lib.vms.count == 2 && lib.vms[1].config.rdpForward?.hostPort != vm.config.rdpForward?.hostPort)

        // Unattended setup disc.
        check("computer name", Unattend.computerName(from: "My Windows 11!") == "MYWINDOWS11" && Unattend.computerName(from: "123") == "VAMP")
        let xml = Unattend.xml(.init(username: "carter", password: "p<&>\"w", computerName: "TEST"))
        check("answer file is valid XML", (try? XMLDocument(xmlString: xml)) != nil)
        check("answer file bypasses checks", xml.contains("BypassTPMCheck") && xml.contains("BypassSecureBootCheck") && xml.contains("arm64"))
        do {
            let iso = try await Unattend.buildISO(account: .init(username: "u", password: "p", computerName: "T"), into: vm.paths.bundle)
            vm.config.setupISOPath = iso
            let a = QEMUCommand.arguments(vm.config, paths: vm.paths, tools: lib.tools)
            let bytes = (try? Data(contentsOf: URL(fileURLWithPath: iso))) ?? Data()
            func joliet(_ n: String) -> Bool { bytes.range(of: n.data(using: .utf16BigEndian)!) != nil }
            check("setup disc has Joliet autounattend.xml + script", joliet("autounattend.xml") && joliet("vamp-setup.ps1"))
            check("setup disc attached as CD 3", a.contains { $0.contains("cdrom2") })
        } catch { check("setup disc built", false, error.localizedDescription) }
        check("ISO finder runs", true, ISOFinder.windowsARM() ?? "no ISO in Downloads")

        // The driver link must survive its http:// redirects under App Transport Security.
        var head = URLRequest(url: DriverStore.url)
        head.httpMethod = "HEAD"
        let (code, final): (Int, String) = await withCheckedContinuation { cont in
            let t = URLSession.shared.dataTask(with: head) { _, resp, err in
                let h = resp as? HTTPURLResponse
                cont.resume(returning: (h?.statusCode ?? 0, h?.url?.absoluteString ?? err?.localizedDescription ?? "?"))
            }
            t.delegate = HTTPSUpgrader.shared
            t.resume()
        }
        check("driver download link reachable over https", code == 200 && final.hasPrefix("https://"), final)

        print(ok ? "ALL PASSED" : "SOME CHECKS FAILED")
        return ok
    }

    /// Dev aid: unattended Windows install in a temp root, screenshots every 30 s, then force off.
    static func trialInstall(iso: String, outDir: String, minutes: Double) async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vamp-trial")
        try? FileManager.default.removeItem(at: root)
        setenv("VAMP_ROOT", root.path, 1)
        let lib = Library()
        do {
            let vm = try await lib.createWindowsAutomatic(name: "Trial", cpus: 4, memoryMB: 4096, diskGB: 64, iso: iso,
                                                          username: "trial", password: "Trial-123", fetchDrivers: false)
            vm.start()
            let end = Date().addingTimeInterval(minutes * 60)
            var n = 0
            while Date() < end {
                try? await Task.sleep(for: .seconds(30))
                n += 1
                if let f = vm.lastFrame, let png = NSBitmapImageRep(cgImage: f).representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: String(format: "%@/t%03d.png", outDir, n)))
                }
                print("t+\(n * 30)s state=\(vm.state.title) err=\(vm.lastError ?? "-")")
                if !vm.state.isOn { break }
            }
            vm.forceOff()
            try? await Task.sleep(for: .seconds(4))
        } catch { print("trial failed: \(error)") }
        try? FileManager.default.removeItem(at: root)
    }

    static func frameHasContent(_ img: CGImage?) -> Bool {
        guard let img, let data = img.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return false }
        let n = CFDataGetLength(data)
        var i = 0
        while i < n { if p[i] > 40 { return true }; i += 4 * 97 }
        return false
    }
}

/// Debug aid: `VAMP_SNAPSHOT=<dir>` renders each screen to PNGs, then quits. Windows go to a
/// non-main display and the app never activates (doesn't steal focus).
@MainActor
enum SnapshotDriver {
    static var outDir: String? { ProcessInfo.processInfo.environment["VAMP_SNAPSHOT"] }

    static func start(lib: Library) {
        guard let dir = outDir else { return }
        NSApp.setActivationPolicy(.accessory)
        Task {
            try? await Task.sleep(for: .seconds(1))
            moveOffMainDisplay()
            if lib.vms.isEmpty {
                var cfg = VMConfig(name: "Windows 11", os: .windows11)
                cfg.memoryMB = 2048
                cfg.sound = false
                _ = try? await lib.create(cfg, diskGB: 80)
            }
            guard let vm = lib.vms.first else { NSApp.terminate(nil); return }
            lib.selection = vm.id
            for tab in [DetailTab.overview, .hardware, .snapshots] {
                lib.tab = tab
                try? await Task.sleep(for: .seconds(1))
                capture(dir, "\(tab.rawValue)-off")
            }
            lib.showNewVM = true
            try? await Task.sleep(for: .seconds(1))
            capture(dir, "new-vm")
            lib.showNewVM = false
            lib.tab = .console
            vm.notice = "Sent the power-button signal. Windows may take a moment (or ask) before shutting down."
            try? await Task.sleep(for: .seconds(1))
            capture(dir, "console-notice")
            vm.notice = nil
            vm.start()
            try? await Task.sleep(for: .seconds(9))
            capture(dir, "console-running")
            lib.sidebarHidden = true
            try? await Task.sleep(for: .seconds(1))
            capture(dir, "console-nosidebar")
            lib.sidebarHidden = false
            lib.tab = .overview
            try? await Task.sleep(for: .seconds(2.5))
            capture(dir, "overview-running")
            lib.tab = .log
            try? await Task.sleep(for: .seconds(2.5))
            capture(dir, "log")
            vm.forceOff()
            try? await Task.sleep(for: .seconds(2))
            NSApp.terminate(nil)
        }
    }

    static func moveOffMainDisplay() {
        guard let w = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 500 }) else { return }
        let main = NSScreen.screens.first
        if let other = NSScreen.screens.first(where: { $0 != main }) {
            let f = other.visibleFrame
            w.setFrame(NSRect(x: f.minX, y: f.minY, width: min(1440, f.width), height: min(900, f.height)), display: true)
        } else {
            w.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        }
    }

    static func capture(_ dir: String, _ name: String) {
        guard let w = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 500 }),
              let view = w.contentView?.superview ?? w.contentView else { return }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
    }
}
