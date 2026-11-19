import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(Library.self) private var lib

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                Sidebar().frame(width: 290)
                FNRule(vertical: true)
                if let vm = lib.selected {
                    VMDetail(vm: vm)
                } else {
                    EmptyLibrary()
                }
            }
            if lib.showNewVM { NewVMModal() }
            if let vm = lib.confirmDelete { DeleteModal(vm: vm) }
        }
        .background(FN.bg)
        .preferredColorScheme(.dark)
    }
}

struct Sidebar: View {
    @Environment(Library.self) private var lib

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: FN.s2) {
                FNWordmark(size: 38)
                Text("Virtualization Architecture\nfor Mac Platform").fnCaption()
            }
            .padding(.horizontal, FN.s4).padding(.top, 40).padding(.bottom, FN.s4)

            if !lib.tools.ready || lib.tools.swtpm == nil { ToolsWarning().padding(.horizontal, FN.s4).padding(.bottom, FN.s3) }

            Button { lib.showNewVM = true } label: { Label("New Virtual Machine", systemImage: "plus") }
                .buttonStyle(.fnPrimary)
                .padding(.horizontal, FN.s4).padding(.bottom, FN.s4)

            HStack {
                Text("Library").fnLabel()
                Spacer()
                Text("\(lib.runningCount) running").fnLabel(lib.runningCount > 0 ? FN.accent : FN.muted)
            }
            .padding(.horizontal, FN.s4).padding(.bottom, FN.s1)
            FNRule()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(lib.vms) { vm in VMRow(vm: vm) }
                }
            }
            Spacer(minLength: 0)
            FNRule()
            HStack {
                Text("Host").fnLabel()
                Spacer()
                Text("\(Host.cpus) cores · \(Fmt.mem(Host.memoryMB))").fnCaption()
            }
            .padding(FN.s4)
        }
        .background(FN.bg)
    }
}

struct VMRow: View {
    @Environment(Library.self) private var lib
    let vm: VM

    var body: some View {
        let selected = lib.selection == vm.id
        Button { lib.selection = vm.id } label: {
            HStack(spacing: FN.s2) {
                ZStack {
                    Rectangle().fill(FN.track)
                    if let t = vm.thumbnail {
                        Image(nsImage: t).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: vm.config.os.symbol).font(.system(size: 14)).foregroundStyle(FN.muted)
                    }
                }
                .frame(width: 64, height: 40).clipped()
                .overlay(Rectangle().strokeBorder(selected ? FN.bg : FN.hair, lineWidth: 1))
                VStack(alignment: .leading, spacing: 4) {
                    Text(vm.config.name).font(FN.mono(13, .semibold)).foregroundStyle(selected ? FN.bg : FN.fg).lineLimit(1)
                    HStack(spacing: 6) {
                        FNPill(text: vm.config.suspended && !vm.state.isOn ? "Suspended" : vm.state.title,
                               state: selected ? .inverse : (vm.config.suspended && !vm.state.isOn ? .warn : vm.state.pill))
                        if vm.state.isOn {
                            Text(String(format: "%.0f%% CPU", vm.cpuPercent)).fnCaption(selected ? FN.bg : FN.muted)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, FN.s4).padding(.vertical, FN.s2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(FNRowBackground(selected: selected))
        .contextMenu {
            if vm.state.isOn {
                Button("Shut Down") { vm.shutdown() }
                Button("Force Off") { vm.forceOff() }
            } else {
                Button(vm.config.suspended ? "Resume" : "Start") { vm.start() }
                Button("Clone") { lib.clone(vm) }
                Button("Move to Trash…") { lib.confirmDelete = vm }
            }
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([vm.paths.bundle]) }
        }
    }
}

struct ToolsWarning: View {
    @Environment(Library.self) private var lib

    var body: some View {
        VStack(alignment: .leading, spacing: FN.s1) {
            Text(lib.tools.ready ? "TPM support missing" : "QEMU not installed").fnLabel(FN.warn)
            Text("Install with Homebrew, then click Check Again:").fnCaption()
            Text("brew install \(lib.tools.missing.joined(separator: " "))").fnData(FN.accent).textSelection(.enabled)
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("brew install \(lib.tools.missing.joined(separator: " "))", forType: .string)
                }
                .buttonStyle(.fn(.secondary, compact: true))
                Button("Check Again") { lib.refreshTools() }.buttonStyle(.fn(.secondary, compact: true))
            }
        }
        .padding(FN.s2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fnBorder(FN.warn)
    }
}

struct EmptyLibrary: View {
    @Environment(Library.self) private var lib
    var body: some View {
        VStack(spacing: FN.s4) {
            FNHeading(text: "No virtual machines")
            Text("Create a Windows 11 ARM VM to get started. You'll need the Windows 11 ARM64 ISO from Microsoft.")
                .fnCaption().multilineTextAlignment(.center).frame(maxWidth: 420)
            Button { lib.showNewVM = true } label: { Label("New Virtual Machine", systemImage: "plus") }.buttonStyle(.fnPrimary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DeleteModal: View {
    @Environment(Library.self) private var lib
    let vm: VM

    var body: some View {
        FNModal(width: 520) {
            VStack(alignment: .leading, spacing: FN.s4) {
                FNHeading(text: "Move to Trash")
                Text("\"\(vm.config.name)\" and its virtual disk (\(Fmt.bytes(vm.diskAllocated)) on disk), snapshots and TPM state will move to the Trash. You can restore it from there until you empty the Trash.")
                    .fnBody().fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Cancel") { lib.confirmDelete = nil }.buttonStyle(.fnSecondary).keyboardShortcut(.cancelAction)
                    Button("Move to Trash") { lib.trash(vm); lib.confirmDelete = nil }.buttonStyle(.fnDanger)
                }
            }
        }
    }
}
