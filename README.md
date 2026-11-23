# VAMP

**Virtualization Architecture for Mac Platform**: a VMware-style virtual machine manager for Apple Silicon Macs, built on QEMU with Apple's Hypervisor.framework. It's made first for Windows 11 ARM, and Linux ARM64 works too.

## Features

- **Zero-click Windows 11 install.** Pick the Windows 11 ARM ISO, enter a username and password, and VAMP does the rest: no requirement checks, no disk picker, no Microsoft account, and you land on the desktop signed in.
- **Drivers built in.** VAMP ships the ARM64 virtio drivers (network, display, storage and more) and Windows Setup installs them itself, so networking works from first boot. Nothing is downloaded.
- **Shared clipboard.** Copy and paste text and images between the Mac and Windows through VAMP Tools, a small guest agent that installs automatically and updates itself.
- **Clock sync.** The guest clock is corrected when the Mac wakes from sleep.
- **Reliable NAT networking.** VM DNS keeps working even when your network's first DNS server is dead.
- **Widescreen console.** Docked, expanded, or edge-to-edge full screen in one window.
- **The rest.** Live snapshots (memory and disk), suspend/resume, clone, port forwarding (Remote Desktop and SSH set up automatically), TPM 2.0 via swtpm, sound.

## Install

1. Download **VAMP.dmg** from [Releases](../../releases/latest).
2. Open it and drag **VAMP** onto **Applications**.
3. Open VAMP. It isn't notarized by Apple, so macOS asks once:
   - **macOS 15 or later:** macOS says it can't verify VAMP; click **Done**. Then open **System Settings → Privacy & Security**, scroll down, click **Open Anyway** next to VAMP, and confirm.
   - **macOS 14:** right-click VAMP in Applications, choose **Open**, then **Open**.

That's all. QEMU, the TPM emulator, firmware and Windows drivers are all inside the app, so there's nothing else to install.

**You need** an Apple Silicon Mac with macOS 14 or later, and a Windows 11 ARM64 ISO ([free from Microsoft](https://www.microsoft.com/software-download/windows11arm64)) or any ARM64 Linux ISO.

## Build from source

Building needs Homebrew's `qemu` and `swtpm`. The build copies them, with their libraries and licenses, into the app.

```bash
./scripts/build.sh            # builds build/VAMP.app
./scripts/build.sh --install  # and copies it to /Applications
./scripts/make_dmg.sh         # packs build/VAMP.dmg
```

`VAMP.app/Contents/MacOS/VAMP --selftest` boots a real VM and checks the whole stack.

## Notes

- VM bundles live in `~/Library/Application Support/VAMP/VMs`.
- Windows activation is up to you. VAMP uses Microsoft's generic install key, which selects the edition but doesn't activate it.
- Bundled third-party software keeps its own license. The QEMU, swtpm and library licenses are in `VAMP.app/Contents/Resources/qemu/licenses` (with versions and source links in `SOURCES.txt`). The Windows drivers are from [virtio-win](https://github.com/virtio-win/kvm-guest-drivers-windows); see `Resources/drivers/LICENSE-virtio-win.txt`.
