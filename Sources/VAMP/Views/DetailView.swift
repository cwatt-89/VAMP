import AppKit
import SwiftUI

struct VMDetail: View {
    @Environment(Library.self) private var lib
    let vm: VM

    var body: some View {
        @Bindable var lib = lib
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, FN.s5).padding(.top, 34).padding(.bottom, FN.s3)
            HStack {
                FNSegmented(selection: $lib.tab, items: DetailTab.allCases.map { ($0, $0.title) })
                Spacer()
                if let b = vm.busy {
                    ProgressView().controlSize(.small)
                    Text(b).fnCaption(FN.fg)
                }
            }
            .padding(.horizontal, FN.s5).padding(.bottom, FN.s3)
            banners
            FNRule()
            Group {
                switch lib.tab {
                case .console: ConsolePane(vm: vm)
                case .overview: OverviewTab(vm: vm)
                case .hardware: HardwareTab(vm: vm)
                case .snapshots: SnapshotsTab(vm: vm)
                case .log: LogTab(vm: vm)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(FN.bg)
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: FN.s3) {
            VStack(alignment: .leading, spacing: 6) {
                Stretched(text: vm.config.name, size: 30, scale: 1.45)
                HStack(spacing: FN.s1) {
                    FNPill(text: vm.state.title, state: vm.state.pill)
                    if vm.config.suspended && !vm.state.isOn { FNPill(text: "Suspended", state: .warn, symbol: "moon.fill") }
                    FNPill(text: vm.config.os.title, state: .neutral)
                    Text("\(vm.config.cpus) vCPU · \(Fmt.mem(vm.config.memoryMB)) · \(Fmt.bytes(vm.diskVirtual)) disk").fnCaption()
                }
            }
            Spacer()
            PowerControls(vm: vm)
        }
    }

    @ViewBuilder private var banners: some View {
        if let e = vm.lastError {
            Banner(text: e, color: FN.danger) { vm.lastError = nil }
        }
        if let n = vm.notice {
            Banner(text: n, color: FN.accent) { vm.notice = nil }
        }
    }
}

struct Banner: View {
    let text: String
    let color: Color
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top) {
            Rectangle().fill(color).frame(width: 3)
            Text(text).fnData().textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.fnGhost)
        }
        .padding(FN.s2)
        .background(FN.surface)
        .fnBorder()
        .padding(.horizontal, FN.s5).padding(.bottom, FN.s3)
    }
}

struct PowerControls: View {
    let vm: VM

    var body: some View {
        HStack(spacing: FN.s1) {
            switch vm.state {
            case .stopped:
                if vm.config.suspended {
                    Button("Discard Saved State") { vm.discardSuspendedState() }.buttonStyle(.fn(.ghost))
                }
                Button { vm.start() } label: { Label(vm.config.suspended ? "Resume" : "Start", systemImage: "play.fill") }
                    .buttonStyle(.fnPrimary)
            case .running:
                Button { vm.pause() } label: { Label("Pause", systemImage: "pause.fill") }.buttonStyle(.fn(.secondary, compact: true))
                Button { Task { await vm.suspend() } } label: { Label("Suspend", systemImage: "moon.fill") }.buttonStyle(.fn(.secondary, compact: true))
                Button { vm.reset() } label: { Label("Restart", systemImage: "arrow.clockwise") }.buttonStyle(.fn(.secondary, compact: true))
                Button { vm.shutdown() } label: { Label("Shut Down", systemImage: "power") }.buttonStyle(.fn(.secondary, compact: true))
                Button("Force Off") { vm.forceOff() }.buttonStyle(.fn(.danger, compact: true))
            case .paused:
                Button { vm.resume() } label: { Label("Resume", systemImage: "play.fill") }.buttonStyle(.fn(.primary, compact: true))
                Button { Task { await vm.suspend() } } label: { Label("Suspend", systemImage: "moon.fill") }.buttonStyle(.fn(.secondary, compact: true))
                Button("Force Off") { vm.forceOff() }.buttonStyle(.fn(.danger, compact: true))
            case .starting, .stopping, .suspending:
                ProgressView().controlSize(.small)
                Button("Force Off") { vm.forceOff() }.buttonStyle(.fn(.danger, compact: true))
            }
        }
    }
}

// MARK: - Overview

struct OverviewTab: View {
    @Environment(Library.self) private var lib
    let vm: VM

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FN.s4) {
                HStack(alignment: .top, spacing: FN.s4) {
                    preview
                    VStack(spacing: FN.s2) {
                        HStack(spacing: FN.s2) {
                            FNStatTile(label: "CPU", value: vm.state.isOn ? String(format: "%.0f%%", vm.cpuPercent) : "—",
                                       detail: "\(vm.config.cpus) vCPU of \(Host.cpus)", valueColor: vm.state.isOn ? FN.accent : FN.muted)
                            FNStatTile(label: "Memory", value: vm.state.isOn ? Fmt.bytes(vm.rss) : "—", detail: "\(Fmt.mem(vm.config.memoryMB)) assigned")
                        }
                        HStack(spacing: FN.s2) {
                            FNStatTile(label: "Disk", value: Fmt.bytes(vm.diskAllocated), detail: "of \(Fmt.bytes(vm.diskVirtual)) virtual")
                            TimelineView(.periodic(from: .now, by: 1)) { _ in
                                FNStatTile(label: "Uptime", value: vm.startedAt.map { Fmt.duration(Date().timeIntervalSince($0)) } ?? "—",
                                           detail: vm.config.lastRun.map { "Last run " + Fmt.date.string(from: $0) } ?? "Never started")
                            }
                        }
                    }
                }
                ConnectSection(vm: vm)
                if vm.config.os == .windows11 {
                    if vm.config.autoInstallUser != nil { AutoInstallSection(vm: vm) } else { WindowsGuide(vm: vm) }
                }
                FNSection(title: "Notes") {
                    @Bindable var vm = vm
                    TextEditor(text: $vm.config.notes)
                        .font(FN.mono(12)).scrollContentBackground(.hidden)
                        .frame(minHeight: 70).padding(6).background(FN.bg).fnBorder(FN.hair)
                }
            }
            .padding(FN.s5)
        }
    }

    private var preview: some View {
        ZStack {
            Rectangle().fill(FN.track)
            if vm.state.isOn {
                ConsoleSurface(vm: vm, interactive: false)
            } else if let t = vm.thumbnail {
                Image(nsImage: t).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: vm.config.os.symbol).font(.system(size: 32)).foregroundStyle(FN.hair)
            }
        }
        .frame(width: 400, height: 250)
        .fnBorder(FN.hair)
        .onTapGesture(count: 2) { lib.tab = .console }
        .help("Double-click to open the console")
    }
}

struct ConnectSection: View {
    let vm: VM
    var body: some View {
        FNSection(title: "Connect", caption: "Forwarded ports listen on 127.0.0.1 only (this Mac).") {
            VStack(alignment: .leading, spacing: FN.s2) {
                if vm.config.network == .none {
                    Text("Networking is disconnected for this VM.").fnCaption()
                } else if vm.config.portForwards.isEmpty {
                    Text("No port forwards. Add them under Hardware → Network.").fnCaption()
                }
                ForEach(vm.config.portForwards) { f in
                    HStack {
                        Text(verbatim: f.label.isEmpty ? "Port \(f.guestPort)" : f.label).fnData().frame(width: 180, alignment: .leading)
                        Text(verbatim: "localhost:\(f.hostPort) → guest:\(f.guestPort)/\(f.proto)").fnData(FN.muted).textSelection(.enabled)
                        Spacer()
                        if f.guestPort == 3389 {
                            Button { vm.openRDP() } label: { Label("Open Remote Desktop", systemImage: "display") }
                                .buttonStyle(.fn(.secondary, compact: true)).disabled(!vm.state.isOn)
                        } else if f.guestPort == 22 {
                            Button("Copy ssh Command") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString("ssh -p \(f.hostPort) localhost", forType: .string)
                            }
                            .buttonStyle(.fn(.secondary, compact: true))
                        }
                    }
                    .padding(.vertical, 4)
                    .overlay(alignment: .bottom) { FNRule() }
                }
                if vm.config.rdpForward != nil {
                    Text("Remote Desktop gives a resizable window, clipboard, sound and shared Mac folders. It needs Windows 11 Pro with Remote Desktop turned on, and the Windows App from the Mac App Store.")
                        .fnCaption().fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct AutoInstallSection: View {
    @Environment(Library.self) private var lib
    let vm: VM

    var body: some View {
        FNSection(title: "Automatic install", caption: "Windows sets itself up from the answer disc (CD 3). Nothing to click.") {
            VStack(alignment: .leading, spacing: FN.s2) {
                line("Account", "\(vm.config.autoInstallUser ?? "") (administrator, signs in automatically the first time)")
                line("Edition", "Windows 11 Pro (activate later with your own key in Settings → Activation)")
                if vm.config.driversPending {
                    if let p = lib.drivers.progress {
                        HStack(spacing: FN.s2) {
                            Text("Drivers").fnLabel().frame(width: 120, alignment: .leading)
                            FNBar(fraction: p).frame(width: 220)
                            Text(String(format: "%.0f%% of ~880 MB", p * 100)).fnCaption()
                        }
                    } else if let e = lib.drivers.error {
                        HStack {
                            Text(e).fnCaption(FN.danger)
                            Button("Retry") { lib.attachDriversWhenReady() }.buttonStyle(.fn(.secondary, compact: true))
                        }
                    }
                } else {
                    line("Drivers", "virtio-win attached as CD 2; network, storage and balloon drivers install at first sign-in")
                }
                line("Then", "Remote Desktop turns on and sleep turns off. A log is written to C:\\vamp-setup.log in Windows.")
                Text("The VM restarts a few times during setup. A \"Press any key to boot from CD\" message on those restarts is normal; leave it and it continues from the disk.")
                    .fnCaption().fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func line(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).fnLabel().frame(width: 120, alignment: .leading)
            Text(v).fnData().fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct WindowsGuide: View {
    let vm: VM
    private let steps: [(String, String, String?)] = [
        ("Boot the installer", "Start the VM, open Console, and press a key when it says \"Press any key to boot from CD or DVD\".", nil),
        ("If setup says \"This PC doesn't meet requirements\"", "Click Back, press Shift+F10, run this command, close the window, then click Next again. QEMU's ARM firmware doesn't pass the TPM or Secure Boot through to Windows.", "reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f & reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f"),
        ("Disk", "Windows setup sees the NVMe disk with no extra drivers. Choose it and continue.", nil),
        ("Skip the network requirement", "At \"Let's connect you to a network\", press Shift+F10 and run this command. The VM reboots and offers \"I don't have internet\".", "OOBE\\BYPASSNRO"),
        ("Network driver", "After you reach the desktop, open CD2 (the virtio-win drivers ISO) and run virtio-win-guest-tools, or point Device Manager at the CD's NetKVM\\w11\\ARM64 folder.", nil),
        ("Remote Desktop (optional)", "Settings → System → Remote Desktop → On (Windows 11 Pro). Then use Open Remote Desktop above for a resizable window.", nil),
        ("Screen resolution", "Ramfb has a fixed size. To change it, restart, press Esc at the logo, then Device Manager → OVMF Platform Configuration.", nil),
    ]

    var body: some View {
        FNSection(title: "Windows setup", caption: "Windows 11 ARM is a free download from Microsoft; activate it with your own license.") {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: FN.s1) {
                    Button("Get Windows 11 ARM ISO") { NSWorkspace.shared.open(URL(string: "https://www.microsoft.com/software-download/windows11arm64")!) }
                        .buttonStyle(.fn(.secondary, compact: true))
                    Button("Get virtio-win Drivers") { NSWorkspace.shared.open(URL(string: "https://github.com/virtio-win/virtio-win-pkg-scripts/blob/master/README.md")!) }
                        .buttonStyle(.fn(.secondary, compact: true))
                }
                .padding(.bottom, FN.s3)
                ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                    HStack(alignment: .top, spacing: FN.s3) {
                        Text(String(format: "%02d", i + 1)).fnData(FN.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(s.0).fnSmall()
                            Text(s.1).fnCaption().fixedSize(horizontal: false, vertical: true)
                            if let cmd = s.2 {
                                HStack {
                                    Text(cmd).fnData(FN.accent).textSelection(.enabled)
                                    Button("Type into VM") { vm.type(cmd + "\n") }.buttonStyle(.fn(.ghost)).disabled(!vm.state.isOn)
                                }
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, FN.s2)
                    .overlay(alignment: .bottom) { FNRule() }
                }
            }
        }
    }
}

// MARK: - Snapshots

struct SnapshotsTab: View {
    let vm: VM
    @State private var name = ""
    @State private var armed: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FN.s4) {
                FNSection(title: "Take snapshot",
                          caption: vm.state.isOn ? "Saves disk and memory. Reverting returns to this exact running moment."
                                                 : "VM is off: saves the disk only. Reverting starts from that disk state.") {
                    HStack {
                        FNTextField(placeholder: "Name, e.g. clean-install", text: $name, symbol: "camera.aperture")
                        Button { take() } label: { Label("Take Snapshot", systemImage: "plus") }
                            .buttonStyle(.fnPrimary).disabled(vm.busy != nil)
                    }
                }
                FNSection(title: "Snapshots", caption: "Stored inside the VM's disk image. Each snapshot with memory holds about as much as the VM's RAM in use.") {
                    VStack(spacing: 0) {
                        HStack {
                            Text("Name").fnLabel().frame(maxWidth: .infinity, alignment: .leading)
                            Text("Taken").fnLabel().frame(width: 190, alignment: .leading)
                            Text("Contents").fnLabel().frame(width: 170, alignment: .leading)
                            Spacer().frame(width: 230)
                        }
                        .padding(.bottom, 6)
                        FNRule()
                        if vm.snapshots.isEmpty {
                            Text("No snapshots yet.").fnCaption().padding(.vertical, FN.s3).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(vm.snapshots) { s in row(s) }
                    }
                }
            }
            .padding(FN.s5)
        }
        .task { await vm.refreshDisk() }
    }

    private func row(_ s: SnapshotInfo) -> some View {
        HStack {
            Text(s.name).fnData().frame(maxWidth: .infinity, alignment: .leading)
            Text(Fmt.date.string(from: s.date)).fnData(FN.muted).frame(width: 190, alignment: .leading)
            Group {
                if s.vmStateSize > 0 { FNPill(text: "Disk + memory", state: .ok) } else { FNPill(text: "Disk only", state: .neutral) }
            }
            .frame(width: 170, alignment: .leading)
            HStack(spacing: FN.s1) {
                Button(armed == "r" + s.name ? "Confirm Revert" : "Revert") {
                    if armed == "r" + s.name { armed = nil; Task { await vm.revert(to: s) } } else { armed = "r" + s.name }
                }
                .buttonStyle(.fn(armed == "r" + s.name ? .primary : .secondary, compact: true))
                Button(armed == "d" + s.name ? "Confirm Delete" : "Delete") {
                    if armed == "d" + s.name { armed = nil; Task { await vm.deleteSnapshot(s) } } else { armed = "d" + s.name }
                }
                .buttonStyle(.fn(.danger, compact: true))
            }
            .frame(width: 230, alignment: .trailing)
            .disabled(vm.busy != nil)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { FNRule() }
    }

    private func take() {
        let n = name.isEmpty ? "snapshot-" + DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short) : name
        name = ""
        Task { await vm.takeSnapshot(n) }
    }
}

// MARK: - Log

struct LogTab: View {
    let vm: VM
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("qemu.log").fnLabel()
                Spacer()
                Button("Copy Command Line") {
                    let line = QEMUCommand.shellLine(vm.tools.qemu ?? "qemu-system-aarch64", QEMUCommand.arguments(vm.config, paths: vm.paths, tools: vm.tools))
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(line, forType: .string)
                }
                .buttonStyle(.fn(.secondary, compact: true))
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([vm.paths.log]) }
                    .buttonStyle(.fn(.secondary, compact: true))
            }
            .padding(.horizontal, FN.s5).padding(.vertical, FN.s2)
            FNRule()
            ScrollView {
                Text(text.isEmpty ? "No log yet. Start the VM to create one." : text)
                    .font(FN.mono(11)).foregroundStyle(text.isEmpty ? FN.muted : FN.fg)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(FN.s4)
            }
        }
        .task {
            while !Task.isCancelled {
                let s = (try? String(contentsOf: vm.paths.log, encoding: .utf8)) ?? ""
                text = String(s.suffix(60_000))
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}
