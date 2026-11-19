import AppKit
import SwiftUI

struct HardwareTab: View {
    @Environment(Library.self) private var lib
    let vm: VM
    @State private var growTo = 0

    var body: some View {
        @Bindable var vm = vm
        let locked = vm.state.isOn
        ScrollView {
            VStack(alignment: .leading, spacing: FN.s4) {
                if locked {
                    Text("Shut the VM down to change hardware. Discs can be swapped while it runs.").fnCaption(FN.warn)
                }
                FNSection(title: "General") {
                    VStack(alignment: .leading, spacing: FN.s3) {
                        HWRow("Name") { FNTextField(placeholder: "Name", text: $vm.config.name, width: 320) }
                        HWRow("Guest OS") { FNMenuPicker(selection: $vm.config.os, options: GuestOS.allCases.map { ($0, $0.title) }) }
                    }
                    .disabled(locked)
                }
                FNSection(title: "Processor & memory") {
                    VStack(alignment: .leading, spacing: FN.s3) {
                        HWRow("vCPUs") {
                            FNSegmented(selection: $vm.config.cpus, items: cpuChoices.map { ($0, "\($0)") })
                        }
                        HWRow("Memory") {
                            FNSegmented(selection: $vm.config.memoryMB, items: memChoices.map { ($0, Fmt.mem($0)) })
                        }
                        Text("This Mac has \(Host.cpus) cores and \(Fmt.mem(Host.memoryMB)). Leave at least 4 GB for macOS.").fnCaption()
                    }
                    .disabled(locked)
                }
                FNSection(title: "Storage") {
                    VStack(alignment: .leading, spacing: FN.s3) {
                        HWRow("System disk") {
                            Text("NVMe · \(Fmt.bytes(vm.diskVirtual)) virtual · \(Fmt.bytes(vm.diskAllocated)) used on this Mac").fnData()
                        }
                        HWRow("Grow disk to") {
                            FNMenuPicker(selection: $growTo, options: growChoices.map { ($0, $0 == 0 ? "Choose size" : "\($0) GB") })
                            Button("Resize") { Task { await vm.growDisk(toGB: growTo); growTo = 0 } }
                                .buttonStyle(.fn(.secondary, compact: true)).disabled(growTo == 0 || locked)
                        }
                        .disabled(locked)
                        HWRow("CD 1 (installer)") { mediaRow(slot: 0, path: vm.config.isoPath) }
                        HWRow("CD 2 (drivers)") { mediaRow(slot: 1, path: vm.config.driversISOPath) }
                    }
                }
                FNSection(title: "Network") {
                    VStack(alignment: .leading, spacing: FN.s3) {
                        HWRow("Mode") { FNSegmented(selection: $vm.config.network, items: NetworkMode.allCases.map { ($0, $0.title) }) }
                        HWRow("Adapter") { FNMenuPicker(selection: $vm.config.nic, options: NICModel.allCases.map { ($0, $0.title) }) }
                        HWRow("MAC address") {
                            Text(vm.config.macAddress).fnData().textSelection(.enabled)
                            Button("Regenerate") { vm.config.macAddress = VMConfig.randomMAC() }.buttonStyle(.fn(.ghost))
                        }
                        PortForwardEditor(vm: vm)
                    }
                    .disabled(locked)
                }
                FNSection(title: "Devices") {
                    VStack(alignment: .leading, spacing: FN.s3) {
                        Toggle("TPM 2.0 (required by Windows 11 setup; state kept in the VM bundle)", isOn: $vm.config.tpm).toggleStyle(.fnCheckbox)
                        Toggle("Sound output (Intel HD Audio → this Mac's speakers)", isOn: $vm.config.sound).toggleStyle(.fnCheckbox)
                        HWRow("Display") { FNMenuPicker(selection: $vm.config.display, options: DisplayDevice.allCases.map { ($0, $0.title) }) }
                        Text("Windows ARM has no virtio-gpu driver, so use Framebuffer for Windows. There's no 3D acceleration either way.").fnCaption()
                    }
                    .disabled(locked)
                }
                FNSection(title: "Advanced", caption: "Extra arguments appended to the QEMU command line, separated by spaces.") {
                    FNTextField(placeholder: "-device virtio-balloon-pci", text: $vm.config.extraArgs).disabled(locked)
                }
                FNSection(title: "Bundle") {
                    HStack {
                        Text(vm.paths.bundle.path).fnCaption().textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([vm.paths.bundle]) }.buttonStyle(.fn(.secondary, compact: true))
                        Button("Clone") { lib.clone(vm) }.buttonStyle(.fn(.secondary, compact: true)).disabled(locked)
                        Button("Move to Trash…") { lib.confirmDelete = vm }.buttonStyle(.fn(.danger, compact: true)).disabled(locked)
                    }
                }
            }
            .padding(FN.s5)
        }
    }

    private var cpuChoices: [Int] { [1, 2, 4, 6, 8, 10, 12, 16].filter { $0 <= Host.cpus } }
    private var memChoices: [Int] { [2048, 4096, 6144, 8192, 12288, 16384, 24576, 32768].filter { $0 <= Host.memoryMB - 2048 } }
    private var growChoices: [Int] {
        let cur = Int(vm.diskVirtual / 1_073_741_824)
        return [0] + [64, 80, 128, 160, 256, 384, 512, 1024].filter { $0 > cur }
    }

    private func mediaRow(slot: Int, path: String?) -> some View {
        HStack(spacing: FN.s1) {
            Text(path.map { ($0 as NSString).lastPathComponent } ?? "Empty").fnData(path == nil ? FN.muted : FN.fg)
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 340, alignment: .leading)
                .help(path ?? "")
            Button("Choose…") { if let p = pickISO() { vm.setMedia(slot: slot, path: p) } }.buttonStyle(.fn(.secondary, compact: true))
            Button("Eject") { vm.setMedia(slot: slot, path: nil) }.buttonStyle(.fn(.ghost)).disabled(path == nil)
            if let path, !FileManager.default.fileExists(atPath: path) { FNPill(text: "Missing", state: .danger) }
        }
    }
}

struct HWRow<C: View>: View {
    let label: String
    @ViewBuilder var content: C
    init(_ label: String, @ViewBuilder content: () -> C) {
        self.label = label
        self.content = content()
    }
    var body: some View {
        HStack(spacing: FN.s2) {
            Text(label).fnLabel().frame(width: 150, alignment: .leading)
            content
            Spacer(minLength: 0)
        }
    }
}

struct PortForwardEditor: View {
    @Environment(Library.self) private var lib
    let vm: VM

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Port forwards").fnLabel()
                Spacer()
                Button { add(guest: 3389, label: "Remote Desktop") } label: { Text("+ RDP") }.buttonStyle(.fn(.ghost))
                Button { add(guest: 22, label: "SSH") } label: { Text("+ SSH") }.buttonStyle(.fn(.ghost))
                Button { add(guest: 80, label: "") } label: { Text("+ Custom") }.buttonStyle(.fn(.ghost))
            }
            ForEach(vm.config.portForwards) { f in
                HStack(spacing: FN.s1) {
                    FNTextField(placeholder: "Label", text: binding(f.id, \.label), width: 170)
                    FNMenuPicker(selection: binding(f.id, \.proto), options: [("tcp", "TCP"), ("udp", "UDP")])
                    Text("localhost").fnCaption()
                    FNTextField(placeholder: "host", text: intBinding(f.id, \.hostPort), width: 80)
                    Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(FN.muted)
                    Text("guest").fnCaption()
                    FNTextField(placeholder: "guest", text: intBinding(f.id, \.guestPort), width: 80)
                    if Library.portInUse(f.hostPort) && !vm.state.isOn { FNPill(text: "Port busy", state: .warn) }
                    Spacer()
                    Button { vm.config.portForwards.removeAll { $0.id == f.id } } label: { Image(systemName: "xmark") }.buttonStyle(.fnGhost)
                }
            }
        }
    }

    private func add(guest: Int, label: String) {
        vm.config.portForwards.append(PortForward(hostPort: lib.freePort(from: guest == 3389 ? 3390 : guest == 22 ? 2222 : 8080), guestPort: guest, label: label))
    }

    private func binding<T>(_ id: UUID, _ kp: WritableKeyPath<PortForward, T>) -> Binding<T> {
        Binding(get: { vm.config.portForwards.first { $0.id == id }![keyPath: kp] },
                set: { v in if let i = vm.config.portForwards.firstIndex(where: { $0.id == id }) { vm.config.portForwards[i][keyPath: kp] = v } })
    }

    private func intBinding(_ id: UUID, _ kp: WritableKeyPath<PortForward, Int>) -> Binding<String> {
        Binding(get: { vm.config.portForwards.first { $0.id == id }.map { String($0[keyPath: kp]) } ?? "" },
                set: { s in
                    if let n = Int(s.filter(\.isNumber)), (1...65535).contains(n), let i = vm.config.portForwards.firstIndex(where: { $0.id == id }) {
                        vm.config.portForwards[i][keyPath: kp] = n
                    }
                })
    }
}

