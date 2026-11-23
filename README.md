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

## Requirements

- Apple Silicon Mac, macOS 14 or later
- [Homebrew](https://brew.sh) QEMU and swtpm:

  ```bash
  brew install qemu swtpm
  ```

- A Windows 11 ARM64 ISO ([download from Microsoft](https://www.microsoft.com/software-download/windows11arm64)) or any ARM64 Linux ISO

## Install

Download `VAMP.zip` from [Releases](../../releases), unzip it, and move `VAMP.app` to Applications. The app is not notarized, so the first time, right-click it and choose **Open**. Or run:

```bash
xattr -dr com.apple.quarantine /Applications/VAMP.app
```

## Build from source

```bash
./scripts/build.sh            # builds build/VAMP.app
./scripts/build.sh --install  # and copies it to /Applications
```

`VAMP.app/Contents/MacOS/VAMP --selftest` boots a real VM and checks the whole stack.

## Notes

- VM bundles live in `~/Library/Application Support/VAMP/VMs`.
- Windows activation is up to you. VAMP uses Microsoft's generic install key, which selects the edition but doesn't activate it.
- The bundled drivers are from the [virtio-win](https://github.com/virtio-win/kvm-guest-drivers-windows) project; see `Resources/drivers/LICENSE-virtio-win.txt`.
