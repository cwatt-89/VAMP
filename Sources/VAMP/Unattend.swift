import Foundation

/// Builds a small "VAMPSETUP" CD holding autounattend.xml + a first-sign-in script, so Windows 11 ARM
/// installs with zero clicks: no requirement checks, no disk picker, no Microsoft account or network
/// requirement, local account created and signed in, virtio drivers + Remote Desktop set up on first logon.
enum Unattend {
    struct Account {
        var username: String
        var password: String
        var computerName: String
        /// Windows time-zone ID matching the Mac ("Central Standard Time"); nil leaves Setup's default.
        var timeZone: String? = nil
    }

    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// NetBIOS rules: 1–15 chars, letters/digits/hyphen, not all digits.
    /// NetBIOS-safe computer name. It must differ from the account name: when they match, Windows
    /// resolves the account to the machine itself, so it never joins Administrators and the
    /// first-logon setup (RDP, drivers, power settings) silently doesn't run.
    static func computerName(from vmName: String, username: String = "") -> String {
        let cleaned = vmName.uppercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" }
        var s = String(String.UnicodeScalarView(cleaned)).prefix(15)
        if s.isEmpty || s.allSatisfy(\.isNumber) { s = "VAMP" }
        if String(s).caseInsensitiveCompare(username) == .orderedSame { s = s.prefix(12) + "-PC" }
        return String(s)
    }

    static func xml(_ a: Account) -> String {
        let user = xmlEscape(a.username)
        let pass = xmlEscape(a.password)
        let comp = xmlEscape(a.computerName)
        let tz = a.timeZone.map { "<TimeZone>\(xmlEscape($0))</TimeZone>" } ?? ""
        let arch = #"processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State""#
        func reg(_ order: Int, _ key: String, _ name: String) -> String {
            """
                    <RunSynchronousCommand wcm:action="add"><Order>\(order)</Order><Path>reg add \(key) /v \(name) /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
            """
        }
        let lab = #"HKLM\SYSTEM\Setup\LabConfig"#
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <unattend xmlns="urn:schemas-microsoft-com:unattend">
          <settings pass="windowsPE">
            <component name="Microsoft-Windows-International-Core-WinPE" \(arch)>
              <SetupUILanguage><UILanguage>en-US</UILanguage></SetupUILanguage>
              <InputLocale>en-US</InputLocale><SystemLocale>en-US</SystemLocale><UILanguage>en-US</UILanguage><UserLocale>en-US</UserLocale>
            </component>
            <component name="Microsoft-Windows-Setup" \(arch)>
              <RunSynchronous>
        \(reg(1, lab, "BypassTPMCheck"))
        \(reg(2, lab, "BypassSecureBootCheck"))
        \(reg(3, lab, "BypassRAMCheck"))
        \(reg(4, lab, "BypassStorageCheck"))
        \(reg(5, lab, "BypassCPUCheck"))
              </RunSynchronous>
              <DiskConfiguration>
                <Disk wcm:action="add">
                  <DiskID>0</DiskID>
                  <WillWipeDisk>true</WillWipeDisk>
                  <CreatePartitions>
                    <CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>260</Size></CreatePartition>
                    <CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition>
                    <CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
                  </CreatePartitions>
                  <ModifyPartitions>
                    <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>FAT32</Format><Label>System</Label></ModifyPartition>
                    <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>3</PartitionID><Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter></ModifyPartition>
                  </ModifyPartitions>
                </Disk>
              </DiskConfiguration>
              <ImageInstall>
                <OSImage>
                  <InstallTo><DiskID>0</DiskID><PartitionID>3</PartitionID></InstallTo>
                  <InstallFrom><MetaData wcm:action="add"><Key>/IMAGE/NAME</Key><Value>Windows 11 Pro</Value></MetaData></InstallFrom>
                </OSImage>
              </ImageInstall>
              <UserData>
                <AcceptEula>true</AcceptEula>
                <!-- Microsoft's public generic install key for Pro: selects the edition, does not activate. -->
                <ProductKey><Key>VK7JG-NPHTM-C97JM-9MPGT-3V66T</Key><WillShowUI>OnError</WillShowUI></ProductKey>
              </UserData>
            </component>
          </settings>
          <settings pass="specialize">
            <component name="Microsoft-Windows-Shell-Setup" \(arch)>
              <ComputerName>\(comp)</ComputerName>
            </component>
            <component name="Microsoft-Windows-Deployment" \(arch)>
              <RunSynchronous>
                <RunSynchronousCommand wcm:action="add"><Order>1</Order><Path>reg add HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\OOBE /v BypassNRO /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
              </RunSynchronous>
            </component>
          </settings>
          <settings pass="oobeSystem">
            <component name="Microsoft-Windows-International-Core" \(arch)>
              <InputLocale>en-US</InputLocale><SystemLocale>en-US</SystemLocale><UILanguage>en-US</UILanguage><UserLocale>en-US</UserLocale>
            </component>
            <component name="Microsoft-Windows-Shell-Setup" \(arch)>
              \(tz)
              <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <HideLocalAccountScreen>true</HideLocalAccountScreen>
                <ProtectYourPC>3</ProtectYourPC>
              </OOBE>
              <UserAccounts>
                <LocalAccounts>
                  <LocalAccount wcm:action="add">
                    <Name>\(user)</Name><DisplayName>\(user)</DisplayName><Group>Administrators</Group>
                    <Password><Value>\(pass)</Value><PlainText>true</PlainText></Password>
                  </LocalAccount>
                </LocalAccounts>
              </UserAccounts>
              <AutoLogon>
                <Enabled>true</Enabled><LogonCount>1</LogonCount><Username>\(user)</Username>
                <Password><Value>\(pass)</Value><PlainText>true</PlainText></Password>
              </AutoLogon>
              <FirstLogonCommands>
                <SynchronousCommand wcm:action="add">
                  <Order>1</Order>
                  <CommandLine>cmd /c "for %d in (D E F G H I J K L) do @if exist %d:\\vamp-setup.ps1 start "" powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File %d:\\vamp-setup.ps1"</CommandLine>
                  <Description>VAMP guest setup</Description>
                </SynchronousCommand>
                <SynchronousCommand wcm:action="add">
                  <Order>2</Order>
                  <CommandLine>cmd /c "powercfg /change monitor-timeout-ac 0 &amp; powercfg /change monitor-timeout-dc 0 &amp; powercfg /change standby-timeout-ac 0 &amp; powercfg /change standby-timeout-dc 0"</CommandLine>
                  <Description>VAMP keep display on</Description>
                </SynchronousCommand>
              </FirstLogonCommands>
            </component>
          </settings>
        </unattend>
        """
    }

    /// Runs once at first sign-in (hidden): Remote Desktop, no sleep, re-applies VAMP's built-in drivers
    /// (Windows Setup already installed them from the disc's $WinPEDriver$ folder; this is a safety net),
    /// then installs VAMP Tools for the shared clipboard.
    static let setupScript = #"""
    $log = "$env:SystemDrive\vamp-setup.log"
    Start-Transcript -Path $log -Append | Out-Null
    try {
      Set-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
      Enable-NetFirewallRule -Group '@FirewallAPI.dll,-28752' -ErrorAction SilentlyContinue
      powercfg /change monitor-timeout-ac 0
      powercfg /change standby-timeout-ac 0
      powercfg /hibernate off
    } catch { $_ }
    $deadline = (Get-Date).AddMinutes(5)
    do {
      $src = Get-PSDrive -PSProvider FileSystem | ForEach-Object { $_.Root } | Where-Object { Test-Path -LiteralPath (Join-Path $_ '$WinPEDriver$') } | Select-Object -First 1
      if ($src) {
        pnputil /add-driver (Join-Path $src '$WinPEDriver$\*.inf') /subdirs /install
        # VAMP Tools: shared clipboard with the Mac (compiled here, started at every sign-in).
        try { & (Join-Path $src 'VAMP Tools\install.ps1') } catch { $_ }
        break
      }
      Start-Sleep -Seconds 10
    } while ((Get-Date) -lt $deadline)
    Stop-Transcript | Out-Null
    """#

    /// Writes the setup CD into the VM bundle and returns its path.
    static func buildISO(account: Account, into bundle: URL) async throws -> String {
        let fm = FileManager.default
        let stage = fm.temporaryDirectory.appendingPathComponent("vampsetup-\(UUID().uuidString.prefix(8))")
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }
        try xml(account).write(to: stage.appendingPathComponent("autounattend.xml"), atomically: true, encoding: .utf8)
        // Windows PowerShell 5 reads BOM-less files as ANSI; write UTF-8 with BOM.
        var script = Data([0xEF, 0xBB, 0xBF])
        script.append(Data(setupScript.replacingOccurrences(of: "\n", with: "\r\n").utf8))
        try script.write(to: stage.appendingPathComponent("vamp-setup.ps1"))
        let iso = bundle.appendingPathComponent("vampsetup.iso")
        try? fm.removeItem(at: iso)
        try await Shell.check("/usr/bin/hdiutil", ["makehybrid", "-quiet", "-iso", "-joliet", "-default-volume-name", "VAMPSETUP",
                                                   "-o", iso.path, stage.path])
        return iso.path
    }
}

/// Finds a Windows 11 ARM installer ISO the user already downloaded.
enum ISOFinder {
    static func windowsARM() -> String? {
        let fm = FileManager.default
        let dirs = [fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0], fm.urls(for: .desktopDirectory, in: .userDomainMask)[0]]
        var best: (String, Date)?
        for d in dirs {
            for f in (try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
                let n = f.lastPathComponent.lowercased()
                guard f.pathExtension.lowercased() == "iso", n.contains("win"), n.contains("arm") || n.contains("a64") || n.contains("aarch64") else { continue }
                let date = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if best == nil || date > best!.1 { best = (f.path, date) }
            }
        }
        return best?.0
    }
}

/// VAMP's own Windows ARM64 drivers (a ~3 MB virtio-win subset bundled in the app: network, display,
/// storage, balloon, serial, RNG, input). Packed as a CD whose `$WinPEDriver$` folder Windows Setup scans
/// on every drive and installs automatically, so networking works from the first boot with nothing to fetch.
@MainActor
enum DriverDisc {
    static let volume = "VAMPDRIVERS"
    /// Bump when the drivers or VAMP Tools change: VMs pick up the new disc at their next start.
    static let version = "virtio-win-0.1.302-tools8"
    static let toolsFolder = "VAMP Tools"

    /// Bundled driver folder: the app's Resources, or the repo's when run from a dev build.
    static var source: URL? { resource("drivers", marker: "NetKVM/netkvm.inf") }
    /// The VAMP Tools guest agent (shared clipboard): C# source + installer, compiled inside the guest.
    static var toolsSource: URL? { resource("guest", marker: "VAMPTools.cs") }

    private static func resource(_ name: String, marker: String) -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let r = Bundle.main.resourceURL { candidates.append(r.appendingPathComponent(name)) }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var dir = exe.deletingLastPathComponent()
        for _ in 0..<6 { candidates.append(dir.appendingPathComponent("Resources/" + name)); dir.deleteLastPathComponent() }
        return candidates.first { fm.fileExists(atPath: $0.appendingPathComponent(marker).path) }
    }

    static var path: String { Library.root.appendingPathComponent("Cache/vamp-drivers-\(version).iso").path }

    /// True for paths VAMP manages in CD 2 (this disc, older versions of it, or the old virtio-win download).
    static func isManaged(_ p: String) -> Bool {
        let name = (p as NSString).lastPathComponent
        return p.hasPrefix(Library.root.appendingPathComponent("Cache").path)
            && (name.hasPrefix("vamp-drivers-") || name == "virtio-win.iso")
    }

    /// Builds the disc once per driver version (well under a second) and returns its path.
    static func ensure() async throws -> String {
        let fm = FileManager.default
        if fm.fileExists(atPath: path) { return path }
        guard let src = source, let tools = toolsSource else { throw FVError("VAMP's built-in Windows drivers are missing from the app bundle.") }
        let stage = fm.temporaryDirectory.appendingPathComponent("vampdrivers-\(UUID().uuidString.prefix(8))")
        defer { try? fm.removeItem(at: stage) }
        let root = stage.appendingPathComponent("$WinPEDriver$")
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        try fm.copyItem(at: src, to: root)
        for extra in ["LICENSE-virtio-win.txt", "VERSION.txt"] where fm.fileExists(atPath: root.appendingPathComponent(extra).path) {
            try fm.moveItem(at: root.appendingPathComponent(extra), to: stage.appendingPathComponent(extra))
        }
        try fm.copyItem(at: tools, to: stage.appendingPathComponent(toolsFolder))
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let tmp = (path as NSString).deletingPathExtension + ".part.iso" // hdiutil appends .iso to other names
        try? fm.removeItem(atPath: tmp)
        try await Shell.check("/usr/bin/hdiutil", ["makehybrid", "-quiet", "-iso", "-joliet", "-default-volume-name", volume,
                                                   "-o", tmp, stage.path])
        try? fm.removeItem(atPath: path)
        try fm.moveItem(atPath: tmp, toPath: path)
        return path
    }
}

/// The Mac's time zone as a Windows time-zone ID, via ICU's CLDR mapping (libicucore ships with macOS).
enum WindowsTimeZone {
    static func current(_ tz: TimeZone = .current) -> String? {
        typealias Fn = @convention(c) (UnsafePointer<UInt16>, Int32, UnsafeMutablePointer<UInt16>, Int32, UnsafeMutablePointer<Int32>) -> Int32
        guard let lib = dlopen("/usr/lib/libicucore.A.dylib", RTLD_LAZY) ?? dlopen("libicucore.dylib", RTLD_LAZY),
              let sym = dlsym(lib, "ucal_getWindowsTimeZoneID") else { return nil }
        let fn = unsafeBitCast(sym, to: Fn.self)
        let id = Array(tz.identifier.utf16)
        var out = [UInt16](repeating: 0, count: 128)
        var status: Int32 = 0
        let n = id.withUnsafeBufferPointer { fn($0.baseAddress!, Int32(id.count), &out, Int32(out.count), &status) }
        guard status <= 0, n > 0 else { return nil }
        return String(utf16CodeUnits: out, count: Int(n))
    }
}
