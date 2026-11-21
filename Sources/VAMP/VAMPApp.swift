import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let library = Library()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        if SnapshotDriver.outDir == nil {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        SnapshotDriver.start(lib: library)
        DispatchQueue.main.async {
            for w in NSApp.windows where w.styleMask.contains(.titled) {
                w.backgroundColor = FN.NS.bg
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = library.vms.filter { $0.state.isOn }
        if running.isEmpty || SnapshotDriver.outDir != nil { return .terminateNow }
        let a = NSAlert()
        a.messageText = running.count == 1 ? "\"\(running[0].config.name)\" is running" : "\(running.count) virtual machines are running"
        a.informativeText = "Suspend saves each VM's memory to disk so it resumes exactly where it was. Keep Running leaves them running in the background; VAMP reconnects the next time it opens."
        a.addButton(withTitle: "Suspend All")
        a.addButton(withTitle: "Keep Running")
        a.addButton(withTitle: "Cancel")
        switch a.runModal() {
        case .alertFirstButtonReturn:
            Task {
                for vm in running { await vm.suspend() }
                // Give QEMU a moment to exit after "quit".
                for _ in 0..<50 where running.contains(where: { $0.state.isOn }) { try? await Task.sleep(for: .milliseconds(100)) }
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { true }
}

@main
enum Entry {
    static func main() {
        if let i = CommandLine.arguments.firstIndex(of: "--trial-install"), CommandLine.arguments.count > i + 3 {
            let a = CommandLine.arguments
            Task { @MainActor in VM.guestChannelEnabled = false; await SelfTest.trialInstall(iso: a[i + 1], outDir: a[i + 2], minutes: Double(a[i + 3]) ?? 5); exit(0) }
            RunLoop.main.run()
        }
        if let i = CommandLine.arguments.firstIndex(of: "--trial-linux"), CommandLine.arguments.count > i + 3 {
            let a = CommandLine.arguments
            Task { @MainActor in VM.guestChannelEnabled = false; await SelfTest.trialLinux(iso: a[i + 1], seed: a[i + 2], outDir: a[i + 3]); exit(0) }
            RunLoop.main.run()
        }
        if let i = CommandLine.arguments.firstIndex(of: "--guest-script"), CommandLine.arguments.count > i + 3 {
            let a = CommandLine.arguments
            Task { @MainActor in await GuestDriver.run(sock: a[i + 1], script: a[i + 2], outDir: a[i + 3]); exit(0) }
            RunLoop.main.run()
        }
        if let i = CommandLine.arguments.firstIndex(of: "--boot"), CommandLine.arguments.count > i + 1 {
            // Starts a library VM headlessly and leaves it running; the app reattaches when opened.
            let key = CommandLine.arguments[i + 1].lowercased()
            Task { @MainActor in
                VM.guestChannelEnabled = false
                let lib = Library()
                guard let vm = lib.vms.first(where: { $0.id.uuidString.lowercased().hasPrefix(key) || $0.config.name.lowercased() == key })
                else { print("no such VM"); exit(1) }
                vm.start()
                for _ in 0..<120 where vm.state != .running { try? await Task.sleep(for: .milliseconds(500)) }
                print("state: \(vm.state) \(vm.lastError ?? "")")
                exit(vm.state == .running ? 0 : 1)
            }
            RunLoop.main.run()
        }
        if CommandLine.arguments.contains("--selftest") {
            Task { @MainActor in exit(await SelfTest.run() ? 0 : 1) }
            RunLoop.main.run()
        }
        VAMPApp.main()
    }
}

struct VAMPApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        let lib = delegate.library
        Window("VAMP", id: "main") {
            ContentView()
                .environment(lib)
                .frame(minWidth: 1180, minHeight: 720)
        }
        .defaultSize(width: 1440, height: 900)
        .windowStyle(.hiddenTitleBar)
        .commands { VAMPCommands(lib: lib) }

        Settings {
            PreferencesView().environment(lib)
        }
    }
}

struct VAMPCommands: Commands {
    let lib: Library

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Virtual Machine…") { lib.showNewVM = true }.keyboardShortcut("n")
        }
        CommandMenu("Virtual Machine") {
            let vm = lib.selected
            Button("Start / Resume") { vm?.state == .paused ? vm?.resume() : vm?.start() }
                .keyboardShortcut("r").disabled(vm == nil || vm?.state == .running)
            Button("Pause") { vm?.pause() }.disabled(vm?.state != .running)
            Button("Suspend") { if let vm { Task { await vm.suspend() } } }.disabled(vm?.state != .running && vm?.state != .paused)
            Button("Shut Down") { vm?.shutdown() }.disabled(vm?.state != .running)
            Button("Restart") { vm?.reset() }.disabled(vm?.state != .running)
            Button("Force Off") { vm?.forceOff() }.keyboardShortcut(".", modifiers: [.command, .option]).disabled(vm?.state.isOn != true)
            Divider()
            Button("Send Ctrl-Alt-Del") { vm?.sendCtrlAltDel() }.disabled(vm?.state.isOn != true)
            Button("Take Snapshot") {
                if let vm { Task { await vm.takeSnapshot("snapshot-" + DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium)) } }
            }
            .keyboardShortcut("s", modifiers: [.command, .shift]).disabled(vm == nil)
            Button("Clone") { if let vm { lib.clone(vm) } }.disabled(vm == nil || vm?.state.isOn == true)
        }
        CommandGroup(after: .sidebar) {
            Button(lib.sidebarHidden ? "Show Library" : "Hide Library") { lib.sidebarHidden.toggle() }
                .keyboardShortcut("l", modifiers: [.command, .control])
            Button(lib.consoleMode == .docked ? "Expand Console" : "Exit Expanded Console") { lib.toggleExpanded() }
                .keyboardShortcut("e", modifiers: [.command, .control]).disabled(lib.selected == nil)
            Button(lib.consoleMode == .fullScreen ? "Exit Full Screen Console" : "Full Screen Console") { lib.toggleConsoleFullScreen() }
                .keyboardShortcut("f", modifiers: [.command, .shift]).disabled(lib.selected == nil)
            Divider()
            ForEach(Array(DetailTab.allCases.enumerated()), id: \.offset) { i, t in
                Button(t.title) { lib.tab = t }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
            }
        }
    }
}

struct PreferencesView: View {
    @Environment(Library.self) private var lib
    @AppStorage("qemuPrefix") private var prefix = ""

    var body: some View {
        VStack(alignment: .leading, spacing: FN.s4) {
            FNSection(title: "QEMU", caption: "VAMP looks in Homebrew (/opt/homebrew), /usr/local and MacPorts. Set a prefix to use another install.") {
                VStack(alignment: .leading, spacing: FN.s2) {
                    tool("qemu-system-aarch64", lib.tools.qemu)
                    tool("qemu-img", lib.tools.img)
                    tool("swtpm", lib.tools.swtpm)
                    tool("UEFI firmware", lib.tools.firmwareCode)
                    HStack {
                        FNTextField(placeholder: "Custom prefix, e.g. /opt/qemu", text: $prefix)
                        Button("Check Again") { lib.refreshTools() }.buttonStyle(.fn(.secondary, compact: true))
                    }
                }
            }
            FNSection(title: "Storage") {
                HStack {
                    Text(Library.vmsDir.path).fnCaption().textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.open(Library.vmsDir) }.buttonStyle(.fn(.secondary, compact: true))
                }
            }
        }
        .padding(FN.s5)
        .frame(width: 640)
        .background(FN.bg)
        .preferredColorScheme(.dark)
    }

    private func tool(_ name: String, _ path: String?) -> some View {
        HStack {
            Text(name).fnLabel().frame(width: 170, alignment: .leading)
            if let path { Text(path).fnData().lineLimit(1).truncationMode(.middle) } else { FNPill(text: "Not found", state: .danger) }
            Spacer()
        }
    }
}
