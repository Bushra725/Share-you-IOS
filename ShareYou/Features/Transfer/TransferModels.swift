import Foundation
import Network

enum TransferDirection { case send, receive }
enum ItemStatus { case waiting, active, done, failed }
enum TransferRole { case none, host, client }

struct TransferItem: Identifiable, Equatable {
    let id: String
    let name: String
    let size: Int64
    let mime: String
    let direction: TransferDirection
    let peerId: String
    var peerName: String
    var transferred: Int64 = 0
    var status: ItemStatus = .waiting
    var resultURL: URL?
    var error: String?
    /// Same id for every copy of one share, including copies the host forwards.
    var shareKey: String = ""
    /// Device that originally shared the file.
    var originName: String = ""
    /// True when this copy was forwarded by the group host.
    var relay = false

    var progress: Double {
        if status == .done { return 1 }
        guard size > 0 else { return 0 }
        return min(1, max(0, Double(transferred) / Double(size)))
    }
}

struct PeerInfo: Identifiable, Equatable {
    let id: String
    let name: String
    let avatar: Int
}

/// Everything a sender needs to reach a receiver. Encoded into the QR code.
/// JSON keys match Android's `HostInfo.toQr()` exactly so both apps can scan each other.
struct HostInfo: Equatable {
    var name: String
    var avatar: Int
    var ip: String
    var ips: [String]
    var port: Int
    var ssid: String?
    var pass: String?
    /// 1 = WPA2, 3 = WPA3 (Android SoftAp security type)
    var security: Int
    var group: Bool
    /// iOS only: Bonjour service name, lets two iPhones connect peer-to-peer without a shared Wi-Fi. Android ignores it.
    var bonjourName: String?

    func toQR() -> String {
        var o: [String: Any] = [
            "n": name, "a": avatar, "ip": ip, "ips": ips, "p": port,
            "s": ssid ?? "", "k": pass ?? "", "sec": security, "g": group
        ]
        if let bonjourName { o["bn"] = bonjourName }
        let data = (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data()
        return AppConfig.qrPrefix + (String(data: data, encoding: .utf8) ?? "{}")
    }

    static func parse(_ text: String?) -> HostInfo? {
        guard let text, text.hasPrefix(AppConfig.qrPrefix) else { return nil }
        let json = String(text.dropFirst(AppConfig.qrPrefix.count))
        guard let data = json.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ip = o["ip"] as? String else { return nil }
        let ssid = (o["s"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let pass = (o["k"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return HostInfo(
            name: o["n"] as? String ?? "Device",
            avatar: (o["a"] as? NSNumber)?.intValue ?? 0,
            ip: ip,
            ips: o["ips"] as? [String] ?? [],
            port: (o["p"] as? NSNumber)?.intValue ?? Int(AppConfig.transferPort),
            ssid: ssid,
            pass: pass,
            security: (o["sec"] as? NSNumber)?.intValue ?? 1,
            group: (o["g"] as? NSNumber)?.boolValue ?? false,
            bonjourName: o["bn"] as? String
        )
    }
}

struct SessionState: Equatable {
    var role: TransferRole = .none
    var status: String = ""
    var hostInfo: HostInfo?
    var peers: [PeerInfo] = []
    var speed: Double = 0
    var error: String?
    var busy = false
    var group = false
    var disconnected = false
    /// Shown on the receive screen when this iPhone has no Wi-Fi address.
    var networkHint: String?

    var active: Bool { role != .none }
    var connected: Bool { !peers.isEmpty }
}

/// A device advertising `_zapshare._tcp` nearby (Android NSD or another iPhone).
struct NearbyDevice: Identifiable, Hashable {
    let name: String
    let endpoint: NWEndpoint
    var id: String { "\(endpoint)" }

    static func == (a: NearbyDevice, b: NearbyDevice) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// Wire protocol: [type:1][headerLen:4, big-endian][headerJson][raw file bytes (FILE only)]
enum Wire {
    static let hello: UInt8 = 1
    static let file: UInt8 = 2
    static let peers: UInt8 = 3
    static let bye: UInt8 = 4
    static let bufferSize = 512 * 1024
    static let maxHeader = 4 * 1024 * 1024

    static func frame(_ type: UInt8, _ json: [String: Any]) throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: json)
        var out = Data(capacity: 5 + body.count)
        out.append(type)
        var len = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        out.append(body)
        return out
    }
}

/// Anything that can be sent: a local file URL with display metadata.
struct ShareItem: Identifiable, Hashable {
    let url: URL
    let name: String
    let size: Int64
    let mime: String
    var id: String { url.path }

    init(url: URL, name: String? = nil, size: Int64? = nil, mime: String? = nil) {
        self.url = url
        let n = name ?? url.lastPathComponent
        self.name = n
        self.size = size ?? FileUtils.fileSize(url)
        self.mime = mime ?? FileUtils.mimeOf(n)
    }
}

enum TransferError: LocalizedError {
    case closed, badFrame, fileChanged, cannotOpen, timeout, noRoute(String)
    var errorDescription: String? {
        switch self {
        case .closed: return String(localized: "Connection lost")
        case .badFrame: return String(localized: "The other device sent data this app does not understand.")
        case .fileChanged: return String(localized: "File changed while sending")
        case .cannotOpen: return String(localized: "Cannot open file")
        case .timeout: return String(localized: "Timed out")
        case .noRoute(let msg): return msg
        }
    }
}

/// Byte counters written from network queues and read by the UI ticker.
final class ProgressMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [String: Int64] = [:]
    private var window: Int64 = 0

    func add(_ id: String, _ n: Int) {
        lock.lock(); defer { lock.unlock() }
        pending[id, default: 0] += Int64(n)
        window += Int64(n)
    }

    func remove(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        pending.removeValue(forKey: id)
    }

    /// Returns per-item byte totals and the bytes moved since the last call.
    func snapshot() -> ([String: Int64], Int64) {
        lock.lock(); defer { lock.unlock() }
        let w = window
        window = 0
        return (pending, w)
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        pending.removeAll()
        window = 0
    }
}
