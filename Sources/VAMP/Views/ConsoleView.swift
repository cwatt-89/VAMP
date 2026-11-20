import AppKit
import SwiftUI

/// The VM's screen. Click to capture keyboard input (⌘ keys go to the guest as the Windows key);
/// press ⌃⌥ together to release. The pointer is absolute (USB tablet), so it never needs grabbing.
final class ConsoleNSView: NSView {
    weak var vm: VM?
    var interactive = true
    var onCapture: ((Bool) -> Void)?
    private var buttons: UInt8 = 0
    private var pressed = Set<UInt32>()
    private var captured = false { didSet { if captured != oldValue { onCapture?(captured) } } }
    private var scrollAccum: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
        layer?.magnificationFilter = .linear
        layer?.minificationFilter = .trilinear
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ img: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = img
        CATransaction.commit()
    }

    override var acceptsFirstResponder: Bool { interactive }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func becomeFirstResponder() -> Bool { captured = true; return true }
    override func resignFirstResponder() -> Bool { releaseAll(); captured = false; return true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        if let w = window {
            NotificationCenter.default.addObserver(self, selector: #selector(windowResigned), name: NSWindow.didResignKeyNotification, object: w)
        }
    }
    @objc private func windowResigned() { releaseAll() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    // MARK: Geometry

    /// Maps a view point to framebuffer pixels inside the aspect-fit image rect.
    private func fbPoint(_ e: NSEvent) -> (Int, Int)? {
        guard let vm, vm.fbSize.width > 0 else { return nil }
        let p = convert(e.locationInWindow, from: nil)
        let fw = vm.fbSize.width, fh = vm.fbSize.height
        let scale = min(bounds.width / fw, bounds.height / fh)
        let w = fw * scale, h = fh * scale
        let ox = (bounds.width - w) / 2, oy = (bounds.height - h) / 2
        let x = (p.x - ox) / scale
        let y = (bounds.height - p.y - oy) / scale // AppKit is bottom-up
        return (Int(x.rounded(.down)), Int(y.rounded(.down)))
    }

    private func sendPointer(_ e: NSEvent, extra: UInt8 = 0) {
        guard interactive, let (x, y) = fbPoint(e) else { return }
        vm?.vnc?.pointer(x: x, y: y, buttons: buttons | extra)
    }

    // MARK: Mouse

    override func mouseDown(with e: NSEvent) {
        guard interactive else { return }
        if !captured { window?.makeFirstResponder(self) }
        buttons |= 1; sendPointer(e)
    }
    override func mouseUp(with e: NSEvent) { buttons &= ~1; sendPointer(e) }
    override func rightMouseDown(with e: NSEvent) { buttons |= 4; sendPointer(e) }
    override func rightMouseUp(with e: NSEvent) { buttons &= ~4; sendPointer(e) }
    override func otherMouseDown(with e: NSEvent) { buttons |= 2; sendPointer(e) }
    override func otherMouseUp(with e: NSEvent) { buttons &= ~2; sendPointer(e) }
    override func mouseMoved(with e: NSEvent) { sendPointer(e) }
    override func mouseDragged(with e: NSEvent) { sendPointer(e) }
    override func rightMouseDragged(with e: NSEvent) { sendPointer(e) }
    override func otherMouseDragged(with e: NSEvent) { sendPointer(e) }

    override func scrollWheel(with e: NSEvent) {
        guard interactive else { return }
        scrollAccum += e.hasPreciseScrollingDeltas ? e.scrollingDeltaY / 12 : e.scrollingDeltaY
        while abs(scrollAccum) >= 1 {
            let up = scrollAccum > 0
            sendPointer(e, extra: up ? 8 : 16)
            sendPointer(e)
            scrollAccum += up ? -1 : 1
        }
    }

    // MARK: Keyboard

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard captured, window?.firstResponder === self else { return false }
        keyDown(with: e)
        return true
    }

    override func keyDown(with e: NSEvent) {
        guard captured, let q = KeyMap.qnum[e.keyCode] else { return }
        if e.isARepeat && pressed.contains(q) { return } // the guest generates its own key repeat
        pressed.insert(q)
        vm?.vnc?.key(qnum: q, down: true)
        // macOS sends no keyUp for keys released while ⌘ is held; release them right away.
        if e.modifierFlags.contains(.command) && q != 0xDB && q != 0xDC {
            pressed.remove(q)
            vm?.vnc?.key(qnum: q, down: false)
        }
    }

    override func keyUp(with e: NSEvent) {
        guard let q = KeyMap.qnum[e.keyCode], pressed.contains(q) else { return }
        pressed.remove(q)
        vm?.vnc?.key(qnum: q, down: false)
    }

    override func flagsChanged(with e: NSEvent) {
        guard captured, let q = KeyMap.qnum[e.keyCode] else { return }
        let raw = e.modifierFlags.rawValue
        // Device-dependent bits distinguish left/right modifiers (IOKit NX_DEVICE* masks).
        let masks: [UInt16: UInt] = [0x38: 0x02, 0x3C: 0x04, 0x3B: 0x01, 0x3E: 0x2000, 0x3A: 0x20, 0x3D: 0x40, 0x37: 0x08, 0x36: 0x10]
        if e.keyCode == 0x39 { // caps lock: one press/release per toggle
            vm?.vnc?.key(qnum: q, down: true)
            vm?.vnc?.key(qnum: q, down: false)
            return
        }
        guard let m = masks[e.keyCode] else { return }
        let down = raw & m != 0
        if down { pressed.insert(q) } else { pressed.remove(q) }
        vm?.vnc?.key(qnum: q, down: down)

        // ⌃⌥ releases capture.
        let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if f.contains(.control) && f.contains(.option) && !f.contains(.command) && !f.contains(.shift) {
            window?.makeFirstResponder(nil)
        }
    }

    private func releaseAll() {
        for q in pressed { vm?.vnc?.key(qnum: q, down: false) }
        pressed.removeAll()
        if buttons != 0 { buttons = 0 }
    }
}

struct ConsoleSurface: NSViewRepresentable {
    let vm: VM
    var interactive = true
    @Binding var captured: Bool

    init(vm: VM, interactive: Bool = true, captured: Binding<Bool> = .constant(false)) {
        self.vm = vm
        self.interactive = interactive
        _captured = captured
    }

    final class Coordinator {
        let sinkID = UUID()
        var vm: VM?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ConsoleNSView {
        let v = ConsoleNSView(frame: .zero)
        v.vm = vm
        v.interactive = interactive
        v.onCapture = { c in DispatchQueue.main.async { captured = c } }
        context.coordinator.vm = vm
        vm.addSink(context.coordinator.sinkID) { [weak v] img in v?.show(img) }
        return v
    }

    func updateNSView(_ v: ConsoleNSView, context: Context) {
        if context.coordinator.vm !== vm {
            context.coordinator.vm?.removeSink(context.coordinator.sinkID)
            context.coordinator.vm = vm
            v.vm = vm
            v.layer?.contents = nil
            vm.addSink(context.coordinator.sinkID) { [weak v] img in v?.show(img) }
        }
        v.interactive = interactive
    }

    static func dismantleNSView(_ v: ConsoleNSView, coordinator: Coordinator) {
        MainActor.assumeIsolated { coordinator.vm?.removeSink(coordinator.sinkID) }
    }
}

enum ConsoleChrome { case docked, expanded, fullScreen }

/// Console plus its controls. Docked in the Console tab; expanded to fill the window; or full screen,
/// edge to edge, with the controls in a bar that slides down when the pointer reaches the top edge.
struct ConsolePane: View {
    @Environment(Library.self) private var lib
    let vm: VM
    var chrome: ConsoleChrome = .docked
    @State private var captured = false
    @State private var barVisible = true
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        switch chrome {
        case .docked:
            VStack(spacing: 0) {
                dockedToolbar
                FNRule()
                screen
                FNRule()
                statusBar
            }
        case .expanded:
            VStack(spacing: 0) {
                modeBar.padding(.leading, 64) // clear the window's traffic lights
                FNRule()
                screen
                FNRule()
                statusBar
            }
        case .fullScreen:
            ZStack(alignment: .top) {
                screen.ignoresSafeArea()
                // Thin hot zone along the top edge brings the bar back.
                Color.clear.frame(height: 6).frame(maxWidth: .infinity).contentShape(Rectangle())
                    .onHover { if $0 { showBar() } }
                if barVisible {
                    VStack(spacing: 0) {
                        modeBar
                        FNRule()
                        statusBar
                    }
                    .background(FN.bg.opacity(0.94))
                    .onHover { inside in inside ? showBar(autoHide: false) : scheduleHide() }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .background(Color.black)
            .onAppear { showBar() }
        }
    }

    private var screen: some View {
        ZStack {
            if vm.state.isOn {
                ConsoleSurface(vm: vm, captured: $captured)
                if vm.state == .paused || vm.state == .suspending || vm.busy != nil {
                    overlayCard(vm.busy ?? vm.state.title, detail: vm.state == .paused ? "Resume to keep working." : nil)
                }
            } else {
                offScreen
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(chrome == .fullScreen ? Color.black : FN.bg)
    }

    // MARK: Bars

    private var dockedToolbar: some View {
        HStack(spacing: FN.s1) {
            MediaMenu(vm: vm, slot: 0)
            MediaMenu(vm: vm, slot: 1)
            Spacer()
            guestActions
            modeButtons
        }
        .padding(.horizontal, FN.s3).padding(.vertical, FN.s1)
    }

    /// One row for expanded and full screen: identity, discs, guest actions, power, layout.
    private var modeBar: some View {
        HStack(spacing: FN.s1) {
            Stretched(text: vm.config.name, size: 17, scale: 1.3)
            FNPill(text: vm.state.title, state: vm.state.pill).padding(.trailing, FN.s1)
            MediaMenu(vm: vm, slot: 0)
            MediaMenu(vm: vm, slot: 1)
            Spacer(minLength: FN.s2)
            guestActions
            PowerMenu(vm: vm)
            modeButtons
        }
        .padding(.horizontal, FN.s3).padding(.vertical, FN.s1)
    }

    private var guestActions: some View {
        HStack(spacing: FN.s1) {
            Button { vm.sendCtrlAltDel() } label: { Label("Ctrl-Alt-Del", systemImage: "command") }
                .buttonStyle(.fn(.secondary, compact: true))
            Button {
                if let s = NSPasteboard.general.string(forType: .string) { vm.type(s) }
            } label: { Label("Type Clipboard", systemImage: "keyboard") }
                .buttonStyle(.fn(.secondary, compact: true))
                .help("Types the clipboard text into the VM as key presses (US layout)")
            Button {
                if let url = vm.screenshot() { vm.notice = "Saved \(url.lastPathComponent) to the Desktop." }
            } label: { Label("Screenshot", systemImage: "camera") }
                .buttonStyle(.fn(.secondary, compact: true))
        }
        .disabled(!vm.state.isOn)
    }

    private var modeButtons: some View {
        HStack(spacing: FN.s1) {
            if chrome != .fullScreen {
                Button { withAnimation(.easeOut(duration: 0.18)) { lib.toggleExpanded() } } label: {
                    Label(chrome == .expanded ? "Collapse" : "Expand",
                          systemImage: chrome == .expanded ? "arrow.down.right.and.arrow.up.left" : "rectangle.expand.vertical")
                }
                .buttonStyle(.fn(.secondary, compact: true))
                .help(chrome == .expanded ? "Back to the library and tabs (⌃⌘E)" : "Fill the window with the console (⌃⌘E)")
            }
            Button { lib.toggleConsoleFullScreen() } label: {
                Label(chrome == .fullScreen ? "Exit Full Screen" : "Full Screen",
                      systemImage: chrome == .fullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.fn(chrome == .fullScreen ? .primary : .secondary, compact: true))
            .help(chrome == .fullScreen ? "Leave full screen (⇧⌘F)" : "Edge-to-edge console; move the pointer to the top edge for controls (⇧⌘F)")
        }
    }

    private var statusBar: some View {
        HStack(spacing: FN.s3) {
            Circle().fill(captured ? FN.accent : FN.hair).frame(width: 7, height: 7)
            Text(captured ? "Input captured · press ⌃⌥ to release" : "Click the screen to capture keyboard input").fnCaption(captured ? FN.fg : FN.muted)
            if chrome == .fullScreen {
                Text("· pointer to the top edge shows this bar").fnCaption()
            }
            Spacer()
            if vm.config.driversPending, let p = lib.drivers.progress {
                Text(String(format: "Downloading drivers %.0f%%", p * 100)).fnCaption()
                FNBar(fraction: p).frame(width: 100)
            }
            if let n = vm.notice { Text(n).fnCaption(FN.accent).lineLimit(1) }
            if vm.fbSize.width > 0 { Text("\(Int(vm.fbSize.width))×\(Int(vm.fbSize.height))").fnCaption() }
            Text(vm.state.title).fnLabel(vm.state == .running ? FN.accent : FN.muted)
        }
        .padding(.horizontal, FN.s3).padding(.vertical, 6)
    }

    // MARK: Full-screen bar timing

    private func showBar(autoHide: Bool = true) {
        hideTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { barVisible = true }
        if autoHide { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, chrome == .fullScreen else { return }
            withAnimation(.easeIn(duration: 0.2)) { barVisible = false }
        }
    }

    // MARK: Placeholders

    private var offScreen: some View {
        ZStack {
            if let t = vm.thumbnail {
                Image(nsImage: t).resizable().aspectRatio(contentMode: .fit).opacity(0.25)
            }
            VStack(spacing: FN.s3) {
                FNHeading(text: vm.config.suspended ? "Suspended" : "Powered off")
                Text(vm.config.suspended ? "Start to pick up exactly where you left off." : "Start the VM to see its screen here.").fnCaption()
                Button { vm.start() } label: { Label(vm.config.suspended ? "Resume" : "Start", systemImage: "play.fill") }
                    .buttonStyle(.fnPrimary)
            }
        }
    }

    private func overlayCard(_ title: String, detail: String?) -> some View {
        VStack(spacing: FN.s1) {
            Text(title).fnSmall()
            if let detail { Text(detail).fnCaption() }
        }
        .padding(FN.s4)
        .background(FN.surface)
        .fnBorder(FN.hair)
    }
}

/// Power actions folded into one menu so the expanded/full-screen bar stays a single row.
struct PowerMenu: View {
    let vm: VM

    var body: some View {
        Menu {
            switch vm.state {
            case .stopped:
                Button(vm.config.suspended ? "Resume" : "Start") { vm.start() }
            case .running:
                Button("Pause") { vm.pause() }
                Button("Suspend") { Task { await vm.suspend() } }
                Button("Restart") { vm.reset() }
                Button("Shut Down") { vm.shutdown() }
                Divider()
                Button("Force Off", role: .destructive) { vm.forceOff() }
            case .paused:
                Button("Resume") { vm.resume() }
                Button("Suspend") { Task { await vm.suspend() } }
                Divider()
                Button("Force Off", role: .destructive) { vm.forceOff() }
            default:
                Button("Force Off", role: .destructive) { vm.forceOff() }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "power").font(.system(size: 10, weight: .semibold))
                Text("POWER").font(FN.mono(11, .semibold)).tracking(0.6)
            }
            .foregroundStyle(FN.fg)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .overlay(Rectangle().strokeBorder(FN.hair, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}

struct MediaMenu: View {
    let vm: VM
    let slot: Int

    var body: some View {
        let path = slot == 0 ? vm.config.isoPath : vm.config.driversISOPath
        Menu {
            Button("Choose Disc Image…") {
                if let p = pickISO() { vm.setMedia(slot: slot, path: p) }
            }
            Button("Eject") { vm.setMedia(slot: slot, path: nil) }.disabled(path == nil)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "opticaldisc").font(.system(size: 10))
                Text("CD\(slot + 1): " + (path.map { ($0 as NSString).lastPathComponent } ?? "empty"))
                    .font(FN.mono(11, .semibold)).lineLimit(1).truncationMode(.middle)
            }
            .foregroundStyle(path == nil ? FN.muted : FN.fg)
            .frame(maxWidth: 220, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .overlay(Rectangle().strokeBorder(FN.hair, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}

@MainActor
func pickISO() -> String? {
    let p = NSOpenPanel()
    p.allowedContentTypes = [.init(filenameExtension: "iso")!, .init(filenameExtension: "img")!, .diskImage]
    p.allowsOtherFileTypes = true
    p.canChooseDirectories = false
    p.message = "Choose a disc image (.iso)"
    return p.runModal() == .OK ? p.url?.path : nil
}
