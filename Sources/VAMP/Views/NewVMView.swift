import AppKit
import SwiftUI

struct NewVMModal: View {
    @Environment(Library.self) private var lib
    @State private var os: GuestOS = .windows11
    @State private var name = ""
    @State private var iso: String? = ISOFinder.windowsARM()
    @State private var username = NSUserName()
    @State private var password = ""
    @State private var showPassword = false
    @State private var customize = false
    @State private var cpus = min(4, Host.cpus)
    @State private var memMB = Host.memoryMB >= 16384 ? 6144 : 4096
    @State private var diskGB = 80
    @State private var creating = false
    @State private var error: String?

    var body: some View {
        FNModal(width: 720) {
            VStack(alignment: .leading, spacing: FN.s4) {
                FNSectionHeading(title: "New virtual machine",
                                 caption: os == .windows11 ? "Windows installs itself: no setup screens, no clicks. About 15–25 minutes."
                                                           : "ARM64 guests run at near-native speed through Apple's hypervisor.")
                HWRow("Guest") { FNSegmented(selection: $os, items: GuestOS.allCases.map { ($0, $0.title) }) }

                HWRow(os == .windows11 ? "Windows ISO" : "Installer ISO") {
                    Text(iso.map { ($0 as NSString).lastPathComponent } ?? "None").fnData(iso == nil ? FN.muted : FN.fg)
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: 360, alignment: .leading)
                    Button("Choose…") { if let p = pickISO() { iso = p } }.buttonStyle(.fn(.secondary, compact: true))
                }
                if os == .windows11 && iso == nil {
                    HStack(spacing: FN.s1) {
                        Spacer().frame(width: 150)
                        Text("Not found in Downloads.").fnCaption(FN.warn)
                        Button("Download Windows 11 ARM from Microsoft") {
                            NSWorkspace.shared.open(URL(string: "https://www.microsoft.com/software-download/windows11arm64")!)
                        }
                        .buttonStyle(FNLinkStyle())
                    }
                }

                if os == .windows11 {
                    HWRow("Windows user") { FNTextField(placeholder: "username", text: $username, width: 240) }
                    HWRow("Password") {
                        Group {
                            if showPassword {
                                FNTextField(placeholder: "password", text: $password, width: 240)
                            } else {
                                SecureField("", text: $password, prompt: Text("password").foregroundStyle(FN.muted))
                                    .textFieldStyle(.plain).font(FN.mono(12)).foregroundStyle(FN.fg)
                                    .padding(.horizontal, 10).padding(.vertical, 7).frame(width: 240)
                                    .background(FN.bg).overlay(Rectangle().strokeBorder(FN.hair, lineWidth: 1))
                            }
                        }
                        Button(showPassword ? "Hide" : "Show") { showPassword.toggle() }.buttonStyle(.fn(.ghost))
                    }
                    HStack {
                        Spacer().frame(width: 150)
                        Text("Signs in automatically the first time. Needed later for Remote Desktop and the lock screen.")
                            .fnCaption().fixedSize(horizontal: false, vertical: true)
                    }
                }

                HWRow("Size") {
                    Text("\(cpus) vCPU · \(Fmt.mem(memMB)) memory · \(diskGB) GB disk").fnData()
                    Button(customize ? "Done" : "Customize") { customize.toggle() }.buttonStyle(.fn(.ghost))
                }
                if customize {
                    HWRow("Name") { FNTextField(placeholder: lib.defaultName(for: os), text: $name, width: 320) }
                    HWRow("vCPUs") { FNSegmented(selection: $cpus, items: [2, 4, 6, 8].filter { $0 <= Host.cpus }.map { ($0, "\($0)") }) }
                    HWRow("Memory") {
                        FNSegmented(selection: $memMB, items: [4096, 6144, 8192, 12288].filter { $0 <= Host.memoryMB - 2048 }.map { ($0, Fmt.mem($0)) })
                    }
                    HWRow("Disk") {
                        FNSegmented(selection: $diskGB, items: (os == .windows11 ? [64, 80, 128, 256] : [32, 64, 128, 256]).map { ($0, "\($0) GB") })
                        Text("grows as used").fnCaption()
                    }
                }

                if os == .windows11 {
                    Text(lib.drivers.available != nil
                         ? "Network drivers: ready."
                         : "Network drivers (virtio-win, ~880 MB) download once in the background and install themselves when Windows first signs in.")
                        .fnCaption().fixedSize(horizontal: false, vertical: true)
                }
                if let error { Text(error).fnCaption(FN.danger).fixedSize(horizontal: false, vertical: true) }
                FNRule()
                HStack {
                    if creating { ProgressView().controlSize(.small); Text("Preparing…").fnCaption() }
                    Spacer()
                    Button("Cancel") { lib.showNewVM = false }.buttonStyle(.fnSecondary).keyboardShortcut(.cancelAction)
                    Button(os == .windows11 ? "Create & Install Windows" : "Create") { create() }
                        .buttonStyle(.fnPrimary).disabled(!canCreate).keyboardShortcut(.defaultAction)
                }
            }
        }
        .onChange(of: os) { _, new in
            if new == .windows11 { diskGB = max(diskGB, 64); iso = iso ?? ISOFinder.windowsARM() }
        }
    }

    private var canCreate: Bool {
        guard !creating, lib.tools.ready else { return false }
        if os == .windows11 {
            return iso != nil && !username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
        }
        return true
    }

    private func create() {
        let finalName = name.trimmingCharacters(in: .whitespaces).isEmpty ? lib.defaultName(for: os) : name
        creating = true
        error = nil
        Task {
            do {
                let vm: VM
                if os == .windows11, let iso {
                    vm = try await lib.createWindowsAutomatic(name: finalName, cpus: cpus, memoryMB: memMB, diskGB: diskGB, iso: iso,
                                                             username: username.trimmingCharacters(in: .whitespaces), password: password)
                } else {
                    var cfg = VMConfig(name: finalName, os: os)
                    cfg.cpus = cpus
                    cfg.memoryMB = memMB
                    cfg.isoPath = iso
                    vm = try await lib.create(cfg, diskGB: diskGB)
                }
                lib.showNewVM = false
                lib.tab = .console
                vm.start()
            } catch {
                self.error = error.localizedDescription
            }
            creating = false
        }
    }
}
