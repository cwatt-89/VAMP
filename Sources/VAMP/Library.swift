import AppKit
import Foundation

@Observable @MainActor
final class Library {
    var vms: [VM] = []
    var selection: UUID?
    var tab: DetailTab = .overview
    var sidebarHidden = UserDefaults.standard.bool(forKey: "sidebarHidden") {
        didSet { UserDefaults.standard.set(sidebarHidden, forKey: "sidebarHidden") }
    }
    var showNewVM = false
    var confirmDelete: VM?
    var tools = QEMUTools.locate()
    let drivers = DriverStore()

    /// VAMP_ROOT overrides the storage root (self-test and snapshot runs).
    static var root: URL {
        if let r = ProcessInfo.processInfo.environment["VAMP_ROOT"] { return URL(fileURLWithPath: r) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("VAMP")
    }
    static var vmsDir: URL { root.appendingPathComponent("VMs") }

    var selected: VM? { vms.first { $0.id == selection } ?? nil }
    var runningCount: Int { vms.filter { $0.state.isOn }.count }

    init() {
        Library.migrateFromFloydVM()
        load()
    }

    /// The project was called FloydVM: move its storage folder over on first launch so existing VMs carry on.
    /// QEMU keeps its open files across a same-volume move, so this is safe even if a VM is still running.
    static func migrateFromFloydVM() {
        guard ProcessInfo.processInfo.environment["VAMP_ROOT"] == nil else { return }
        let fm = FileManager.default
        let old = root.deletingLastPathComponent().appendingPathComponent("FloydVM")
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: root.path) else { return }
        try? fm.moveItem(at: old, to: root)
    }

    func load() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Library.vmsDir, withIntermediateDirectories: true)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let dirs = (try? fm.contentsOfDirectory(at: Library.vmsDir, includingPropertiesForKeys: nil)) ?? []
        var out: [VM] = []
        for d in dirs where d.pathExtension == "vamp" || d.pathExtension == "floydvm" {
            guard let data = try? Data(contentsOf: d.appendingPathComponent("config.json")),
                  let cfg = try? dec.decode(VMConfig.self, from: data) else { continue }
            if let existing = vms.first(where: { $0.id == cfg.id }) { out.append(existing); continue }
            let vm = VM(config: cfg, bundle: d)
            vm.library = self
            vm.reattachIfRunning()
            out.append(vm)
        }
        vms = out.sorted { $0.config.created < $1.config.created }
        if selection == nil { selection = vms.first?.id }
        for vm in vms { Task { await vm.refreshDisk() } }
        if vms.contains(where: { $0.config.driversPending }) { attachDriversWhenReady() }
    }

    /// Downloads virtio-win in the background and hands it to every VM waiting for it (live if running).
    func attachDriversWhenReady() {
        Task {
            guard let path = await drivers.ensure() else { return }
            for vm in vms where vm.config.driversPending {
                vm.config.driversPending = false
                vm.setMedia(slot: 1, path: path)
            }
        }
    }

    /// Zero-touch Windows 11 ARM: answer-file CD + drivers + first-boot key presses, then starts the VM.
    @discardableResult
    func createWindowsAutomatic(name: String, cpus: Int, memoryMB: Int, diskGB: Int, iso: String,
                                username: String, password: String, fetchDrivers: Bool = true) async throws -> VM {
        var cfg = VMConfig(name: name, os: .windows11)
        cfg.cpus = cpus
        cfg.memoryMB = memoryMB
        cfg.isoPath = iso
        cfg.autoBootCD = true
        cfg.autoInstallUser = username
        if let d = drivers.available { cfg.driversISOPath = d } else { cfg.driversPending = fetchDrivers }
        let vm = try await create(cfg, diskGB: diskGB)
        let account = Unattend.Account(username: username, password: password, computerName: Unattend.computerName(from: name))
        do {
            vm.config.setupISOPath = try await Unattend.buildISO(account: account, into: vm.paths.bundle)
        } catch {
            vm.lastError = "Couldn't build the automatic setup disc: \(error.localizedDescription)"
        }
        if vm.config.driversPending { attachDriversWhenReady() }
        return vm
    }

    func refreshTools() { tools = QEMUTools.locate() }

    /// Next free localhost port at or above `base` that no VM forwards yet and nothing is listening on.
    func freePort(from base: Int) -> Int {
        let used = Set(vms.flatMap { $0.config.portForwards.map(\.hostPort) })
        var p = base
        while used.contains(p) || Library.portInUse(p) { p += 1 }
        return p
    }

    static func portInUse(_ port: Int) -> Bool {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(s) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        return r != 0
    }

    @discardableResult
    func create(_ cfg: VMConfig, diskGB: Int) async throws -> VM {
        var cfg = cfg
        if cfg.os == .windows11 && cfg.rdpForward == nil {
            cfg.portForwards.append(PortForward(hostPort: freePort(from: 3390), guestPort: 3389, label: "Remote Desktop"))
        } else if cfg.os == .linux && !cfg.portForwards.contains(where: { $0.guestPort == 22 }) {
            cfg.portForwards.append(PortForward(hostPort: freePort(from: 2222), guestPort: 22, label: "SSH"))
        }
        let bundle = Library.vmsDir.appendingPathComponent(cfg.id.uuidString + ".vamp")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let vm = VM(config: cfg, bundle: bundle)
        vm.library = self
        do {
            try await DiskImage.create(tools, paths: vm.paths, sizeGB: diskGB)
        } catch {
            try? FileManager.default.removeItem(at: bundle)
            throw error
        }
        vm.save()
        vms.append(vm)
        selection = vm.id
        await vm.refreshDisk()
        return vm
    }

    /// APFS clone of the whole bundle (instant, shares blocks until either copy changes).
    func clone(_ vm: VM) {
        guard !vm.state.isOn else { return }
        var cfg = vm.config
        cfg.id = UUID()
        cfg.name = vm.config.name + " Copy"
        cfg.macAddress = VMConfig.randomMAC()
        cfg.created = Date()
        cfg.lastRun = nil
        cfg.portForwards = cfg.portForwards.map { f in
            var f = f
            f.id = UUID()
            f.hostPort = freePort(from: f.hostPort + 1)
            return f
        }
        let dest = Library.vmsDir.appendingPathComponent(cfg.id.uuidString + ".vamp")
        do {
            try FileManager.default.copyItem(at: vm.paths.bundle, to: dest)
            let copy = VM(config: cfg, bundle: dest)
            copy.library = self
            copy.save()
            vms.append(copy)
            selection = copy.id
            Task { await copy.refreshDisk() }
        } catch {
            vm.lastError = "Clone failed: \(error.localizedDescription)"
        }
    }

    /// Moves the bundle to the Trash (recoverable) rather than deleting it.
    func trash(_ vm: VM) {
        guard !vm.state.isOn else { return }
        do {
            try FileManager.default.trashItem(at: vm.paths.bundle, resultingItemURL: nil)
            vms.removeAll { $0.id == vm.id }
            if selection == vm.id { selection = vms.first?.id }
        } catch {
            vm.lastError = "Couldn't move to Trash: \(error.localizedDescription)"
        }
    }

    func defaultName(for os: GuestOS) -> String {
        let base = os == .windows11 ? "Windows 11" : os == .linux ? "Linux" : "VM"
        var name = base
        var n = 2
        while vms.contains(where: { $0.config.name == name }) { name = "\(base) \(n)"; n += 1 }
        return name
    }
}
