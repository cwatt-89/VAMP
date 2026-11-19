import Foundation
import SwiftUI

enum GuestOS: String, Codable, CaseIterable {
    case windows11, linux, other
    var title: String {
        switch self {
        case .windows11: return "Windows 11 ARM"
        case .linux: return "Linux ARM64"
        case .other: return "Other ARM64"
        }
    }
    var symbol: String {
        switch self {
        case .windows11: return "macwindow"
        case .linux: return "terminal"
        case .other: return "cpu"
        }
    }
}

enum DisplayDevice: String, Codable, CaseIterable {
    case ramfb, virtioGPU
    var title: String { self == .ramfb ? "Basic 4:3 (ramfb)" : "Widescreen (virtio-gpu)" }
}

enum NICModel: String, Codable, CaseIterable {
    case virtio, usbNet
    var title: String { self == .virtio ? "virtio-net (fast, needs driver)" : "USB Ethernet (built-in driver)" }
}

enum NetworkMode: String, Codable, CaseIterable {
    case nat, none
    var title: String { self == .nat ? "NAT" : "Disconnected" }
}

struct PortForward: Codable, Hashable, Identifiable {
    var id = UUID()
    var proto = "tcp"
    var hostPort: Int
    var guestPort: Int
    var label = ""
}

struct VMConfig: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var os: GuestOS = .windows11
    var cpus = 4
    var memoryMB = 6144
    var isoPath: String?
    var driversISOPath: String?
    var tpm = true
    var display: DisplayDevice = .ramfb
    var nic: NICModel = .virtio
    var network: NetworkMode = .nat
    var macAddress = VMConfig.randomMAC()
    var portForwards: [PortForward] = []
    var sound = true
    var notes = ""
    var extraArgs = ""
    var created = Date()
    var lastRun: Date?
    /// A "vamp-suspend" snapshot holds the running state; the next start restores it.
    var suspended = false
    /// Unattended Windows setup CD (autounattend.xml); attached as a third USB CD.
    var setupISOPath: String?
    /// First start of an unattended install: VAMP presses "any key" for the CD boot prompt.
    var autoBootCD = false
    /// The virtio-win ISO is still downloading; attach it as CD 2 when it lands.
    var driversPending = false
    var autoInstallUser: String?

    init(name: String, os: GuestOS) {
        self.name = name
        self.os = os
        if os != .windows11 {
            tpm = false
            display = .virtioGPU
        }
    }

    static func randomMAC() -> String {
        // 52:54:00 is QEMU's locally administered prefix.
        "52:54:00:" + (0..<3).map { _ in String(format: "%02x", Int.random(in: 0...255)) }.joined(separator: ":")
    }

    var rdpForward: PortForward? { portForwards.first { $0.guestPort == 3389 && $0.proto == "tcp" } }

    // Tolerant decoding so older config files keep loading as fields are added.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let def = VMConfig(name: "", os: .windows11)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        os = (try? c.decode(GuestOS.self, forKey: .os)) ?? def.os
        cpus = (try? c.decode(Int.self, forKey: .cpus)) ?? def.cpus
        memoryMB = (try? c.decode(Int.self, forKey: .memoryMB)) ?? def.memoryMB
        isoPath = try? c.decodeIfPresent(String.self, forKey: .isoPath)
        driversISOPath = try? c.decodeIfPresent(String.self, forKey: .driversISOPath)
        tpm = (try? c.decode(Bool.self, forKey: .tpm)) ?? def.tpm
        display = (try? c.decode(DisplayDevice.self, forKey: .display)) ?? def.display
        nic = (try? c.decode(NICModel.self, forKey: .nic)) ?? def.nic
        network = (try? c.decode(NetworkMode.self, forKey: .network)) ?? def.network
        macAddress = (try? c.decode(String.self, forKey: .macAddress)) ?? def.macAddress
        portForwards = (try? c.decode([PortForward].self, forKey: .portForwards)) ?? []
        sound = (try? c.decode(Bool.self, forKey: .sound)) ?? def.sound
        notes = (try? c.decode(String.self, forKey: .notes)) ?? ""
        extraArgs = (try? c.decode(String.self, forKey: .extraArgs)) ?? ""
        created = (try? c.decode(Date.self, forKey: .created)) ?? Date()
        lastRun = try? c.decodeIfPresent(Date.self, forKey: .lastRun)
        suspended = (try? c.decode(Bool.self, forKey: .suspended)) ?? false
        setupISOPath = try? c.decodeIfPresent(String.self, forKey: .setupISOPath)
        autoBootCD = (try? c.decode(Bool.self, forKey: .autoBootCD)) ?? false
        driversPending = (try? c.decode(Bool.self, forKey: .driversPending)) ?? false
        autoInstallUser = try? c.decodeIfPresent(String.self, forKey: .autoInstallUser)
    }
}

enum PowerState: Equatable {
    case stopped, starting, running, paused, stopping, suspending

    var title: String {
        switch self {
        case .stopped: return "Off"
        case .starting: return "Starting"
        case .running: return "Running"
        case .paused: return "Paused"
        case .stopping: return "Shutting down"
        case .suspending: return "Suspending"
        }
    }
    var pill: FNPillState {
        switch self {
        case .stopped: return .neutral
        case .running: return .ok
        case .paused, .starting, .stopping, .suspending: return .warn
        }
    }
    /// QEMU process is alive.
    var isOn: Bool { self != .stopped }
}

struct SnapshotInfo: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var date: Date
    var vmClockSec: Int
    /// Bytes of saved RAM/device state; 0 means disk-only (taken while off).
    var vmStateSize: Int64
}

enum DetailTab: String, CaseIterable {
    case console, overview, hardware, snapshots, log
    var title: String { rawValue.capitalized }
}

struct FVError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

enum Fmt {
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .memory
        f.allowsNonnumericFormatting = false
        return f
    }()
    static func bytes(_ b: Int64) -> String { byteFormatter.string(fromByteCount: max(0, b)) }
    static func mem(_ mb: Int) -> String { mb % 1024 == 0 ? "\(mb / 1024) GB" : String(format: "%.1f GB", Double(mb) / 1024) }
    static func duration(_ s: TimeInterval) -> String {
        let t = Int(max(0, s))
        let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
    static let date: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

enum Host {
    static var cpus: Int { ProcessInfo.processInfo.activeProcessorCount }
    static var memoryMB: Int { Int(ProcessInfo.processInfo.physicalMemory / 1_048_576) }
}
