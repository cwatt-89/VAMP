import AppKit
import Darwin
import Foundation

/// One virtual machine: its saved configuration plus everything about the running QEMU process.
@Observable @MainActor
final class VM: Identifiable {
    let id: UUID
    let paths: VMPaths
    var config: VMConfig {
        didSet { if config != oldValue { save() } }
    }

    var state: PowerState = .stopped
    var lastError: String?
    var notice: String?
    var busy: String?
    var cpuPercent: Double = 0
    var rss: Int64 = 0
    var diskAllocated: Int64 = 0
    var diskVirtual: Int64 = 0
    var startedAt: Date?
    var snapshots: [SnapshotInfo] = []
    var fbSize: CGSize = .zero
    var thumbnail: NSImage?

    @ObservationIgnored private(set) var lastFrame: CGImage?
    @ObservationIgnored private var sinks: [UUID: (CGImage) -> Void] = [:]
    @ObservationIgnored private(set) var qmp: QMPClient?
    @ObservationIgnored private(set) var vnc: VNCClient?
    @ObservationIgnored private var pid: pid_t = 0
    @ObservationIgnored private var exitSource: DispatchSourceProcess?
    @ObservationIgnored private var tpmProc: Process?
    @ObservationIgnored private var statsTimer: Timer?
    @ObservationIgnored private var lastCPU: (ns: Double, at: Date)?
    @ObservationIgnored private var cleanShutdown = false
    @ObservationIgnored weak var library: Library?

    var tools: QEMUTools { library?.tools ?? QEMUTools.locate() }

    init(config: VMConfig, bundle: URL) {
        id = config.id
        self.config = config
        paths = VMPaths(bundle: bundle, id: config.id)
        thumbnail = NSImage(contentsOf: paths.thumbnail)
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try? enc.encode(config).write(to: paths.config, options: .atomic)
    }

    // MARK: Frames

    func addSink(_ id: UUID, _ f: @escaping (CGImage) -> Void) {
        sinks[id] = f
        if let lastFrame { f(lastFrame) }
    }
    func removeSink(_ id: UUID) { sinks[id] = nil }

    private func deliver(_ img: CGImage) {
        lastFrame = img
        let s = CGSize(width: img.width, height: img.height)
        if s != fbSize { fbSize = s }
        for f in sinks.values { f(img) }
    }

    // MARK: Power

    func start(loadVM: String? = nil) {
        guard state == .stopped else { return }
        lastError = nil
        notice = nil
        state = .starting
        Task {
            do { try await launch(loadVM: loadVM) } catch {
                lastError = error.localizedDescription + logTail()
                if ProcStats.alive(pid) { kill(pid, SIGKILL) } else { didExit() }
            }
        }
    }

    private func launch(loadVM: String?) async throws {
        let t = tools
        guard let qemu = t.qemu, t.ready else { throw FVError("QEMU isn't installed. Run: brew install qemu swtpm") }
        let fm = FileManager.default
        try? fm.removeItem(at: paths.run)
        try fm.createDirectory(at: paths.run, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        fm.createFile(atPath: paths.log.path, contents: nil)
        let log = try FileHandle(forWritingTo: paths.log)

        if config.tpm {
            guard let sw = t.swtpm else { throw FVError("swtpm isn't installed (brew install swtpm), or turn off TPM in Hardware.") }
            try fm.createDirectory(at: paths.tpmDir, withIntermediateDirectories: true)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: sw)
            p.arguments = ["socket", "--tpm2", "--tpmstate", "dir=\(paths.tpmDir.path)",
                           "--ctrl", "type=unixio,path=\(paths.tpmSock)", "--terminate"]
            p.standardOutput = log
            p.standardError = log
            try p.run()
            tpmProc = p
            let deadline = Date().addingTimeInterval(5)
            while !fm.fileExists(atPath: paths.tpmSock) {
                if Date() > deadline || !p.isRunning { throw FVError("swtpm didn't start") }
                try await Task.sleep(for: .milliseconds(50))
            }
        }

        let restore = loadVM ?? (config.suspended ? QEMUCommand.suspendTag : nil)
        let args = QEMUCommand.arguments(config, paths: paths, tools: t, loadVM: restore)
        log.write(Data(("$ " + QEMUCommand.shellLine(qemu, args) + "\n\n").utf8))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: qemu)
        p.arguments = args
        p.standardOutput = log
        p.standardError = log
        p.standardInput = FileHandle.nullDevice
        try p.run()
        pid = p.processIdentifier
        cleanShutdown = false
        startedAt = Date()
        config.lastRun = Date()
        watchExit()

        let q = try await QMPClient.connect(path: paths.qmpSock, timeout: 20) { [pid] in ProcStats.alive(pid) }
        attach(q)
        if config.suspended && restore == QEMUCommand.suspendTag {
            config.suspended = false
            _ = try? await q.hmp("delvm \(QEMUCommand.suspendTag)")
        }
        await connectVNC()
        startStats()
        if config.autoBootCD {
            config.autoBootCD = false
            pressThroughBootPrompt()
        }
    }

    /// Taps Enter for the first ~25 s so the Windows installer's "Press any key to boot from CD" never waits.
    /// Only on the very first start: later reboots must fall through to the disk, not restart setup.
    private func pressThroughBootPrompt() {
        let started = Date()
        Task {
            while Date().timeIntervalSince(started) < 25, state.isOn {
                vnc?.key(qnum: 0x1C, down: true)
                vnc?.key(qnum: 0x1C, down: false)
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    /// Reconnects to a QEMU left running by a previous VAMP session ("Keep Running" on quit).
    func reattachIfRunning() {
        guard let s = try? String(contentsOfFile: paths.pidFile, encoding: .utf8),
              let p = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)),
              ProcStats.alive(p), ProcStats.name(p).contains("qemu") else { return }
        pid = p
        state = .starting
        startedAt = (try? FileManager.default.attributesOfItem(atPath: paths.pidFile)[.modificationDate] as? Date) ?? Date()
        watchExit()
        Task {
            do {
                let q = try await QMPClient.connect(path: paths.qmpSock, timeout: 5) { ProcStats.alive(p) }
                attach(q)
                await connectVNC()
                startStats()
                notice = "Reconnected to the running VM."
            } catch {
                lastError = "Found a running QEMU (pid \(p)) but couldn't reconnect: \(error.localizedDescription)"
            }
        }
    }

    private func attach(_ q: QMPClient) {
        qmp = q
        q.onEvent = { [weak self] ev, _ in self?.handle(event: ev) }
        Task {
            let st = (try? await q.execute("query-status")) as? [String: Any]
            let running = st?["running"] as? Bool ?? true
            if state == .starting { state = running ? .running : .paused }
        }
    }

    private func handle(event: String) {
        switch event {
        case "STOP": if state == .running { state = .paused }
        case "RESUME": if state == .paused || state == .starting { state = .running }
        case "SHUTDOWN":
            cleanShutdown = true
            if state != .suspending { state = .stopping }
        default: break
        }
    }

    private func connectVNC() async {
        guard let v = try? await VNCClient.connect(path: paths.vncSock, timeout: 5) else { return }
        vnc = v
        v.onFrame = { [weak self] img in self?.deliver(img) }
    }

    private func watchExit() {
        exitSource?.cancel()
        let src = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        src.setEventHandler { [weak self] in self?.didExit() }
        src.resume()
        exitSource = src
        if !ProcStats.alive(pid) { didExit() }
    }

    private func didExit() {
        guard state != .stopped || pid != 0 else { return }
        let wasStarting = state == .starting
        exitSource?.cancel()
        exitSource = nil
        qmp?.close(); qmp = nil
        vnc?.close(); vnc = nil
        if let t = tpmProc, t.isRunning { t.terminate() }
        tpmProc = nil
        statsTimer?.invalidate(); statsTimer = nil
        pid = 0
        cpuPercent = 0
        rss = 0
        lastCPU = nil
        startedAt = nil
        state = .stopped
        if let frame = lastFrame {
            let rep = NSBitmapImageRep(cgImage: frame)
            try? rep.representation(using: .png, properties: [:])?.write(to: paths.thumbnail)
            thumbnail = NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height))
        }
        try? FileManager.default.removeItem(at: paths.run)
        if lastError == nil, wasStarting || (!cleanShutdown && logTail().contains("qemu-system")) {
            lastError = "QEMU stopped unexpectedly." + logTail()
        }
        Task { await refreshDisk() }
    }

    private func logTail() -> String {
        guard let s = try? String(contentsOf: paths.log, encoding: .utf8) else { return "" }
        let lines = s.split(separator: "\n").filter { !$0.hasPrefix("$ ") && !$0.contains("Data client disconnected") }.suffix(4)
        return lines.isEmpty ? "" : "\n" + lines.joined(separator: "\n")
    }

    func pause() { Task { try? await qmp?.execute("stop") } }
    func resume() { Task { try? await qmp?.execute("cont") } }
    func reset() { Task { try? await qmp?.execute("system_reset") } }

    /// ACPI power button; the guest decides how to respond.
    func shutdown() {
        Task {
            try? await qmp?.execute("system_powerdown")
            notice = "Sent the power-button signal. Windows may take a moment (or ask) before shutting down."
        }
    }

    func forceOff() {
        cleanShutdown = true
        let p = pid
        Task {
            if qmp != nil { _ = try? await qmp?.execute("quit") } else if p > 0 { kill(p, SIGTERM) }
            try? await Task.sleep(for: .seconds(3))
            if ProcStats.alive(p), p == pid { kill(p, SIGKILL) }
        }
    }

    /// Saves RAM + device state into the disk image, then quits. The next Start resumes exactly here.
    func suspend() async {
        guard let q = qmp, state == .running || state == .paused else { return }
        let prior = state
        state = .suspending
        busy = "Saving memory state…"
        defer { busy = nil }
        do {
            _ = try await q.execute("stop")
            _ = try await q.hmp("savevm \(QEMUCommand.suspendTag)")
            config.suspended = true
            cleanShutdown = true
            _ = try? await q.execute("quit")
        } catch {
            lastError = "Suspend failed: \(error.localizedDescription)"
            state = prior
            if prior == .running { _ = try? await q.execute("cont") }
        }
    }

    func discardSuspendedState() {
        Task {
            if let img = tools.img {
                for url in [paths.disk, paths.vars] { _ = await Shell.run(img, ["snapshot", "-d", QEMUCommand.suspendTag, url.path]) }
            }
            config.suspended = false
        }
    }

    // MARK: Console helpers

    func sendCtrlAltDel() {
        Task {
            try? await qmp?.execute("send-key", ["keys": ["ctrl", "alt", "delete"].map { ["type": "qcode", "data": $0] }])
        }
    }

    /// Types text as US-layout key presses (for product keys, passwords, commands in the installer).
    func type(_ text: String) {
        guard let v = vnc else { return }
        Task.detached {
            for ch in text {
                guard let (code, shift) = KeyMap.typing[ch] else { continue }
                if shift { v.key(qnum: KeyMap.leftShift, down: true) }
                v.key(qnum: code, down: true)
                v.key(qnum: code, down: false)
                if shift { v.key(qnum: KeyMap.leftShift, down: false) }
                try? await Task.sleep(for: .milliseconds(12))
            }
        }
    }

    func screenshot() -> URL? {
        guard let frame = lastFrame else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let dir = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let url = dir.appendingPathComponent("\(config.name) \(f.string(from: Date())).png")
        guard let png = NSBitmapImageRep(cgImage: frame).representation(using: .png, properties: [:]),
              (try? png.write(to: url)) != nil else { return nil }
        return url
    }

    // MARK: Removable media

    /// Slot 0 is the installer CD, slot 1 the drivers CD. Swaps live when running.
    func setMedia(slot: Int, path: String?) {
        if slot == 0 { config.isoPath = path } else { config.driversISOPath = path }
        guard let q = qmp else { return }
        Task {
            do {
                if let path {
                    try await q.execute("blockdev-change-medium", ["id": "cdrom\(slot)", "filename": path, "format": "raw"])
                } else {
                    try await q.execute("eject", ["id": "cdrom\(slot)", "force": true])
                }
            } catch { lastError = "Couldn't change CD: \(error.localizedDescription)" }
        }
    }

    // MARK: Snapshots

    func refreshDisk() async {
        let t = tools
        let d = await DiskImage.info(t, paths.disk)
        let v = await DiskImage.info(t, paths.vars)
        diskVirtual = d?.virtual ?? 0
        let alloc = try? paths.disk.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize
        diskAllocated = Int64(alloc ?? 0)
        var byName: [String: SnapshotInfo] = [:]
        for s in (d?.snapshots ?? []) + (v?.snapshots ?? []) {
            if var e = byName[s.name] {
                e.vmStateSize = max(e.vmStateSize, s.vmStateSize)
                byName[s.name] = e
            } else { byName[s.name] = s }
        }
        snapshots = byName.values.filter { $0.name != QEMUCommand.suspendTag && $0.name != "floydvm-suspend" }.sorted { $0.date > $1.date }
    }

    static func sanitize(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return String(name.trimmingCharacters(in: .whitespaces).unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
    }

    func takeSnapshot(_ raw: String) async {
        let name = VM.sanitize(raw)
        guard !name.isEmpty else { return }
        busy = state.isOn ? "Saving snapshot with memory…" : "Saving snapshot…"
        defer { busy = nil }
        do {
            if let q = qmp, state.isOn {
                _ = try await q.hmp("savevm \(name)")
            } else if let img = tools.img {
                for url in [paths.disk, paths.vars] { try await Shell.check(img, ["snapshot", "-c", name, url.path]) }
            }
            notice = "Snapshot \"\(name)\" saved."
        } catch { lastError = "Snapshot failed: \(error.localizedDescription)" }
        await refreshDisk()
    }

    func revert(to s: SnapshotInfo) async {
        busy = "Reverting to \(s.name)…"
        defer { busy = nil }
        do {
            if let q = qmp, state.isOn {
                _ = try await q.hmp("loadvm \(s.name)")
                if s.vmStateSize == 0 { _ = try? await q.execute("system_reset") }
            } else if s.vmStateSize > 0 {
                config.suspended = false
                start(loadVM: s.name)
            } else if let img = tools.img {
                try await Shell.check(img, ["snapshot", "-a", s.name, paths.disk.path])
                _ = await Shell.run(img, ["snapshot", "-a", s.name, paths.vars.path])
                config.suspended = false
            }
            notice = "Reverted to \"\(s.name)\"."
        } catch { lastError = "Revert failed: \(error.localizedDescription)" }
    }

    func deleteSnapshot(_ s: SnapshotInfo) async {
        busy = "Deleting snapshot…"
        defer { busy = nil }
        if let q = qmp, state.isOn {
            do { _ = try await q.hmp("delvm \(s.name)") } catch { lastError = "Delete failed: \(error.localizedDescription)" }
        } else if let img = tools.img {
            for url in [paths.disk, paths.vars] { _ = await Shell.run(img, ["snapshot", "-d", s.name, url.path]) }
        }
        await refreshDisk()
    }

    func growDisk(toGB gb: Int) async {
        guard !state.isOn, let img = tools.img else { return }
        busy = "Resizing disk…"
        defer { busy = nil }
        do {
            try await Shell.check(img, ["resize", paths.disk.path, "\(gb)G"])
            notice = "Disk grown to \(gb) GB. Extend the partition inside the guest (Windows: Disk Management → Extend Volume)."
        } catch { lastError = error.localizedDescription }
        await refreshDisk()
    }

    // MARK: Stats

    private func startStats() {
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleStats() }
        }
        sampleStats()
    }

    private func sampleStats() {
        guard pid > 0, let s = ProcStats.sample(pid) else { return }
        let now = Date()
        if let l = lastCPU {
            let dt = now.timeIntervalSince(l.at)
            if dt > 0 { cpuPercent = (s.cpuNs - l.ns) / 1e9 / dt * 100 }
        }
        lastCPU = (s.cpuNs, now)
        rss = s.rss
    }

    // MARK: RDP

    func openRDP() {
        guard let f = config.rdpForward else { return }
        let dir = Library.root.appendingPathComponent("rdp")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(VM.sanitize(config.name) + ".rdp")
        let body = """
        full address:s:127.0.0.1:\(f.hostPort)
        prompt for credentials:i:1
        screen mode id:i:1
        dynamic resolution:i:1
        audiomode:i:0
        redirectclipboard:i:1
        drivestoredirect:s:*
        """
        try? body.write(to: url, atomically: true, encoding: .utf8)
        if NSWorkspace.shared.urlForApplication(toOpen: url) == nil {
            lastError = "No Remote Desktop app found. Install \"Windows App\" from the Mac App Store, then try again."
            return
        }
        NSWorkspace.shared.open(url)
    }
}
