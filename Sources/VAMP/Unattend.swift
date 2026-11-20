import Foundation

/// Builds a small "VAMPSETUP" CD holding autounattend.xml + a first-sign-in script, so Windows 11 ARM
/// installs with zero clicks: no requirement checks, no disk picker, no Microsoft account or network
/// requirement, local account created and signed in, virtio drivers + Remote Desktop set up on first logon.
enum Unattend {
    struct Account {
        var username: String
        var password: String
        var computerName: String
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

    /// Runs once at first sign-in (hidden): Remote Desktop, no sleep, then waits for the virtio-win CD
    /// (it may still be downloading on the Mac) and installs its ARM64 drivers — network first.
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
    $deadline = (Get-Date).AddHours(3)
    while ((Get-Date) -lt $deadline) {
      $src = Get-PSDrive -PSProvider FileSystem | ForEach-Object { $_.Root } | Where-Object { Test-Path (Join-Path $_ 'NetKVM') } | Select-Object -First 1
      if ($src) {
        $infs = Get-ChildItem $src -Recurse -Filter *.inf -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match '\\w11\\ARM64\\' }
        $infs | Sort-Object { $_.FullName -notmatch 'NetKVM' } | ForEach-Object { pnputil /add-driver $_.FullName /install }
        break
      }
      Start-Sleep -Seconds 15
    }
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

/// Downloads and caches virtio-win.iso (once, ~880 MB) for every Windows VM.
@Observable @MainActor
final class DriverStore {
    static let url = URL(string: "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso")!
    static var cached: URL { Library.root.appendingPathComponent("Cache/virtio-win.iso") }

    var progress: Double?
    var error: String?
    @ObservationIgnored private var waiters: [CheckedContinuation<String?, Never>] = []
    @ObservationIgnored private var task: URLSessionDownloadTask?
    @ObservationIgnored private var observation: NSKeyValueObservation?

    var available: String? { FileManager.default.fileExists(atPath: DriverStore.cached.path) ? DriverStore.cached.path : nil }

    /// Returns the cached ISO path, downloading it first if needed (nil on failure).
    func ensure() async -> String? {
        if let available { return available }
        return await withCheckedContinuation { cont in
            waiters.append(cont)
            if task == nil { begin() }
        }
    }

    private func begin() {
        error = nil
        progress = 0
        let t = URLSession.shared.downloadTask(with: DriverStore.url) { [weak self] tmp, resp, err in
            var result: String?
            var failure: String?
            if let tmp, (resp as? HTTPURLResponse)?.statusCode == 200 {
                let dest = DriverStore.cached
                try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: dest)
                do { try FileManager.default.moveItem(at: tmp, to: dest); result = dest.path } catch { failure = error.localizedDescription }
            } else {
                failure = err?.localizedDescription ?? "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)"
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.progress = nil
                self.task = nil
                self.observation = nil
                if let failure { self.error = "Driver download failed: \(failure)" }
                let w = self.waiters
                self.waiters = []
                for c in w { c.resume(returning: result) }
            }
        }
        observation = t.progress.observe(\.fractionCompleted) { [weak self] p, _ in
            let f = p.fractionCompleted
            DispatchQueue.main.async { self?.progress = f }
        }
        t.delegate = HTTPSUpgrader.shared
        task = t
        t.resume()
    }
}

/// fedorapeople's "stable" link redirects to plain http://, which App Transport Security refuses.
/// Follow the redirect over https instead (the same paths are served there).
final class HTTPSUpgrader: NSObject, URLSessionTaskDelegate {
    static let shared = HTTPSUpgrader()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        var r = request
        if let u = r.url, u.scheme == "http", var c = URLComponents(url: u, resolvingAgainstBaseURL: false) {
            c.scheme = "https"
            r.url = c.url
        }
        completionHandler(r)
    }
}
