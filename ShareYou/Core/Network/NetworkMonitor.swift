import Foundation
import Network

/// Internet / Wi-Fi reachability (NWPathMonitor). Transfers work offline; this is used for
/// features that need the internet (sign-in, purchases, ads) and for Wi-Fi hints.
@MainActor
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    @Published private(set) var isOnline = true
    @Published private(set) var isOnWiFi = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "shareyou.netmonitor")
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let wifi = path.usesInterfaceType(.wifi)
            Task { @MainActor in
                self?.isOnline = online
                self?.isOnWiFi = wifi
            }
        }
        monitor.start(queue: queue)
    }
}

/// Local IPv4 addresses of this iPhone.
enum NetUtils {
    struct Address: Hashable { let interface: String; let ip: String }

    static func ipv4Addresses() -> [Address] {
        var out: [Address] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let flags = Int32(p.pointee.ifa_flags)
            if let addr = p.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
               (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let name = String(cString: p.pointee.ifa_name)
                    let ip = String(cString: host)
                    if !ip.hasPrefix("169.254.") { out.append(Address(interface: name, ip: ip)) }
                }
            }
            ptr = p.pointee.ifa_next
        }
        return out
    }

    /// Wi-Fi address (en0).
    static var wifiIP: String? { ipv4Addresses().first { $0.interface == "en0" }?.ip }

    /// Address while this iPhone's Personal Hotspot is on and someone is connected (bridge100, usually 172.20.10.1).
    static var hotspotIP: String? { ipv4Addresses().first { $0.interface.hasPrefix("bridge") }?.ip }

    /// Every LAN address other devices may reach, best first.
    static func lanIPs() -> [String] {
        let all = ipv4Addresses().filter { isPrivate($0.ip) && !$0.interface.hasPrefix("pdp_ip") && !$0.interface.hasPrefix("utun") }
        let ranked = all.sorted { score($0) > score($1) }
        var seen = Set<String>()
        return ranked.map(\.ip).filter { seen.insert($0).inserted }
    }

    private static func score(_ a: Address) -> Int {
        if a.interface == "en0" { return 3 }
        if a.interface.hasPrefix("bridge") { return 2 }
        if a.interface.hasPrefix("en") { return 1 }
        return 0
    }

    static func isPrivate(_ ip: String) -> Bool {
        let p = ip.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4 else { return false }
        return p[0] == 10 || (p[0] == 172 && (16...31).contains(p[1])) || (p[0] == 192 && p[1] == 168)
    }
}
