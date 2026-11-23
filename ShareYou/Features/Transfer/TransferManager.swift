import Foundation
import Network
import NetworkExtension
import UIKit
import Photos

/// The transfer engine (port of Android's `TransferManager`).
///  - HOST   = receiver / group owner. Listens on TCP 48520, advertises `_zapshare._tcp` over Bonjour
///             (Wi-Fi and Apple peer-to-peer Wi-Fi) and shows a QR code.
///  - CLIENT = sender / group member. Scans the QR (joining an Android phone's offline hotspot when the QR
///             carries one), or picks a nearby device, then connects.
/// Once connected both sides can send to each other. In group mode the host relays files to everyone.
@MainActor
final class TransferManager: ObservableObject {
    static let shared = TransferManager()

    @Published private(set) var session = SessionState()
    @Published private(set) var items: [TransferItem] = []
    @Published private(set) var nearby: [NearbyDevice] = []

    private var peers: [String: PeerConnection] = [:]
    private var listener: NWListener?
    private var browser: NWBrowser?
    private let meter = ProgressMeter()
    /// share key → connection that first delivered it in this group session
    private var groupFiles: [String: String] = [:]
    private var groupMembers: [PeerInfo] = []
    private var ticker: Timer?
    private var tickCount = 0
    private var lastTick = Date()
    private var smoothed: Double = 0
    private var joinedSSID: String?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private(set) var finishedCount = 0

    private init() {}

    // MARK: - Host (receive / create group)

    func startHost(group: Bool) {
        stop()
        items = []
        finishedCount = 0
        session = SessionState(role: .host, status: String(localized: "Preparing…"), busy: true, group: group)
        do {
            let params = NWParameters.tcp
            params.includePeerToPeer = true
            params.allowLocalEndpointReuse = true
            if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
                tcp.noDelay = true
                tcp.enableKeepalive = true
            }
            guard let port = NWEndpoint.Port(rawValue: AppConfig.transferPort) else { return }
            let l = try NWListener(using: params, on: port)
            let serviceName = Prefs.shared.deviceName
            l.service = NWListener.Service(name: serviceName, type: AppConfig.bonjourType)
            l.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in self?.accept(conn) }
            }
            l.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.listenerChanged(state, serviceName: serviceName) }
            }
            listener = l
            l.start(queue: DispatchQueue(label: "shareyou.listener"))
        } catch {
            session.busy = false
            session.error = String(localized: "Could not start receiving. \(error.localizedDescription)")
        }
    }

    private func listenerChanged(_ state: NWListener.State, serviceName: String) {
        switch state {
        case .ready:
            session.hostInfo = makeHostInfo(serviceName: serviceName)
            session.busy = false
            session.status = session.group
                ? String(localized: "Group ready. Members scan the QR to join")
                : String(localized: "Waiting for sender to scan…")
            updateNetworkHint()
            beginKeepAlive()
            startTicker()
            if session.networkHint != nil { AnalyticsService.log(.networkHintShown) }
            if session.group { AnalyticsService.log(.groupCreate) }
            else { AnalyticsService.log(.receiveStart) }
        case .failed(let error):
            session.busy = false
            if case .posix(let code) = error, code == .EADDRINUSE {
                session.error = String(localized: "Another app is using the transfer port. Close it and try again.")
            } else {
                session.error = String(localized: "Could not start receiving. \(error.localizedDescription)")
            }
            listener?.cancel()
            listener = nil
        default:
            break
        }
    }

    private func makeHostInfo(serviceName: String) -> HostInfo {
        let lan = NetUtils.lanIPs()
        let ip = NetUtils.wifiIP ?? lan.first ?? "0.0.0.0"
        return HostInfo(name: Prefs.shared.deviceName, avatar: Prefs.shared.avatar, ip: ip, ips: lan,
                        port: Int(AppConfig.transferPort), ssid: nil, pass: nil, security: 1,
                        group: session.group, bonjourName: serviceName)
    }

    private func updateNetworkHint() {
        session.networkHint = NetUtils.lanIPs().isEmpty
            ? String(localized: "This iPhone is not on Wi-Fi. Another iPhone nearby can still connect directly. For an Android phone: join the same Wi-Fi, or turn on Personal Hotspot on this iPhone and connect the Android phone to it.")
            : nil
    }

    private func groupLimit() -> Int {
        DayUnlock.groupLarge() ? DayUnlock.fullGroupMembers : DayUnlock.freeGroupMembers
    }

    private func accept(_ conn: NWConnection) {
        guard session.role == .host else { conn.cancel(); return }
        if session.group && peers.count >= groupLimit() {
            conn.cancel()
            Router.shared.showToast(String(localized: "Group is full"))
            return
        }
        let q = DispatchQueue(label: "shareyou.peer.in")
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: Task { @MainActor in self?.attach(conn, queue: q) }
            case .failed: conn.cancel()
            default: break
            }
        }
        conn.start(queue: q)
    }

    private func attach(_ conn: NWConnection, queue: DispatchQueue) {
        let p = PeerConnection(connection: conn, queue: queue, manager: self, meter: meter,
                               myName: Prefs.shared.deviceName, myAvatar: Prefs.shared.avatar)
        peers[p.id] = p
        p.start()
    }

    // MARK: - Client (send / join group)

    /// Connect using a scanned QR code.
    func connect(_ info: HostInfo) async {
        stop()
        items = []
        finishedCount = 0
        session = SessionState(role: .client, status: String(localized: "Connecting to \(info.name)…"), busy: true, group: info.group)
        do {
            if let ssid = info.ssid {
                session.status = String(localized: "Joining \(info.name)'s hotspot…")
                try await HotspotJoiner.join(ssid: ssid, passphrase: info.pass)
                joinedSSID = ssid
                for _ in 0..<25 where NetUtils.wifiIP == nil {
                    try await Task.sleep(nanoseconds: 400_000_000)
                }
            }
            let port = NWEndpoint.Port(rawValue: UInt16(clamping: info.port)) ?? NWEndpoint.Port(rawValue: AppConfig.transferPort)!
            let own = NetUtils.wifiIP
            var seen = Set<String>()
            let ips = ([info.ip] + info.ips)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && $0 != "0.0.0.0" && $0 != own && seen.insert($0).inserted }
            var endpoints: [NWEndpoint] = []
            if info.ssid == nil, let bn = info.bonjourName {
                endpoints.append(.service(name: bn, type: AppConfig.bonjourType, domain: "local.", interface: nil))
            }
            endpoints += ips.map { .hostPort(host: NWEndpoint.Host($0), port: port) }
            guard !endpoints.isEmpty else {
                throw TransferError.noRoute(String(localized: "Could not reach \(info.name). Keep both screens open and retry."))
            }
            guard let pair = await Self.openConnection(endpoints, attempts: info.ssid != nil ? 6 : 3, wifiOnly: info.ssid != nil) else {
                throw TransferError.noRoute(info.ssid == nil
                    ? String(localized: "Could not reach \(info.name). Join the same Wi-Fi (or keep Wi-Fi and Bluetooth on for iPhone to iPhone), then try again.")
                    : String(localized: "Could not reach \(info.name). Keep both screens open and retry."))
            }
            attach(pair.0, queue: pair.1)
            session.busy = false
            session.status = String(localized: "Connected")
            session.hostInfo = info
            beginKeepAlive()
            startTicker()
            AnalyticsService.log(.connectAttempt, ["method": Self.connectMethod(info), "group": info.group ? 1 : 0])
        } catch {
            cleanupNetwork()
            session.busy = false
            session.error = error.localizedDescription
            AnalyticsService.log(.connectFailed, ["method": Self.connectMethod(info), "reason": error.localizedDescription])
        }
    }

    /// Connect to a device found by Bonjour (same Wi-Fi, or iPhone-to-iPhone peer-to-peer).
    func connect(nearby device: NearbyDevice) async {
        stopBrowsing()
        stop()
        items = []
        finishedCount = 0
        session = SessionState(role: .client, status: String(localized: "Connecting to \(device.name)…"), busy: true)
        AnalyticsService.log(.connectAttempt, ["method": "nearby", "group": 0])
        guard let pair = await Self.openConnection([device.endpoint], attempts: 3, wifiOnly: false) else {
            session.busy = false
            session.error = String(localized: "Could not reach \(device.name). Keep both screens open and retry.")
            AnalyticsService.log(.connectFailed, ["method": "nearby", "reason": "unreachable"])
            return
        }
        attach(pair.0, queue: pair.1)
        session.busy = false
        session.status = String(localized: "Connected")
        beginKeepAlive()
        startTicker()
    }

    private static func connectMethod(_ info: HostInfo) -> String {
        if info.ssid != nil { return "hotspot" }
        if info.bonjourName != nil { return "qr_ios" }
        if info.name == info.ip { return "ip" }
        return "qr_wifi"
    }

    /// Manual IP entry (Android "Manual IP").
    func connect(ip: String) async {
        let info = HostInfo(name: ip, avatar: 0, ip: ip, ips: [], port: Int(AppConfig.transferPort),
                            ssid: nil, pass: nil, security: 1, group: false, bonjourName: nil)
        await connect(info)
    }

    nonisolated private static func openConnection(_ endpoints: [NWEndpoint], attempts: Int, wifiOnly: Bool) async -> (NWConnection, DispatchQueue)? {
        for attempt in 0..<attempts {
            for ep in endpoints {
                if let pair = await tryConnect(ep, timeout: 2.5, wifiOnly: wifiOnly) { return pair }
            }
            if attempt < attempts - 1 { try? await Task.sleep(nanoseconds: 700_000_000) }
        }
        return nil
    }

    nonisolated private static func tryConnect(_ endpoint: NWEndpoint, timeout: Double, wifiOnly: Bool) async -> (NWConnection, DispatchQueue)? {
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        if wifiOnly { params.requiredInterfaceType = .wifi }
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.enableKeepalive = true
            tcp.connectionTimeout = Int(timeout.rounded(.up))
        }
        let q = DispatchQueue(label: "shareyou.peer.out")
        let conn = NWConnection(to: endpoint, using: params)
        let once = OnceFlag()
        return await withCheckedContinuation { (c: CheckedContinuation<(NWConnection, DispatchQueue)?, Never>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { c.resume(returning: (conn, q)) }
                case .failed, .waiting:
                    if once.claim() { conn.cancel(); c.resume(returning: nil) }
                case .cancelled:
                    if once.claim() { c.resume(returning: nil) }
                default:
                    break
                }
            }
            conn.start(queue: q)
            q.asyncAfter(deadline: .now() + timeout) {
                if once.claim() { conn.cancel(); c.resume(returning: nil) }
            }
        }
    }

    // MARK: - Nearby discovery

    func startBrowsing() {
        guard browser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = true
        let b = NWBrowser(for: .bonjour(type: AppConfig.bonjourType, domain: nil), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let list: [NearbyDevice] = results.compactMap { r in
                if case let .service(name, _, _, _) = r.endpoint { return NearbyDevice(name: name, endpoint: r.endpoint) }
                return nil
            }
            Task { @MainActor in
                guard let self else { return }
                let me = Prefs.shared.deviceName
                var seen = Set<String>()
                self.nearby = list.filter { $0.name != me && seen.insert($0.name).inserted }
            }
        }
        b.start(queue: .main)
        browser = b
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        nearby = []
    }

    // MARK: - Sending

    /// Queue files for every connected device.
    func send(_ list: [ShareItem]) {
        let targets = Array(peers.values)
        let total = list.reduce(Int64(0)) { $0 + ($1.size > 0 ? $1.size : FileUtils.fileSize($1.url)) }
        AnalyticsService.log(.sendStart, [
            "files_count": list.count,
            "total_bytes": AnalyticsService.bytes(total),
            "devices": targets.count
        ])
        guard !targets.isEmpty else {
            session.error = String(localized: "No device connected")
            return
        }
        let premium = StoreService.shared.isPremium
        var blocked = false
        for share in list {
            let size = share.size > 0 ? share.size : FileUtils.fileSize(share.url)
            let mime = FileUtils.normalizeMime(share.name, share.mime)
            if !premium && size > AppConfig.freeFileLimit {
                blocked = true
                continue
            }
            let key = UUID().uuidString
            for p in targets {
                let item = TransferItem(id: UUID().uuidString, name: share.name, size: size, mime: mime,
                                        direction: .send, peerId: p.id, peerName: p.name,
                                        resultURL: share.url, shareKey: key, originName: Prefs.shared.deviceName)
                items.append(item)
                p.enqueueFile(item, url: share.url)
            }
        }
        if blocked {
            AnalyticsService.log(.fileLimitHit)
            session.error = String(localized: "Files over 1 GB need Premium")
        }
    }

    // MARK: - Callbacks from PeerConnection

    func onPeerHello(_ p: PeerConnection) {
        AnalyticsService.log(.connectSuccess, ["method": session.role == .host ? "incoming" : "outgoing"])
        if session.role == .client && session.group { AnalyticsService.log(.groupJoin) }
        refreshPeers()
        if session.role == .host && session.group {
            let list = peers.values.filter(\.helloReceived).map { $0.info() }
                + [PeerInfo(id: "host", name: Prefs.shared.deviceName, avatar: Prefs.shared.avatar)]
            peers.values.forEach { $0.enqueuePeers(list) }
        }
    }

    func onPeerList(_ list: [PeerInfo]) {
        groupMembers = list
        refreshPeers()
    }

    func onPeerClosed(_ p: PeerConnection) {
        guard peers.removeValue(forKey: p.id) != nil else { return }
        for i in items.indices where items[i].peerId == p.id && (items[i].status == .waiting || items[i].status == .active) {
            items[i].status = .failed
            items[i].error = String(localized: "Disconnected")
        }
        refreshPeers()
        if session.role == .client && peers.isEmpty {
            session.disconnected = true
            session.status = String(localized: "Disconnected")
            cleanupNetwork()
        } else if session.role == .host && session.group {
            onPeerHello(p)
        }
    }

    private func refreshPeers() {
        let direct = peers.values.filter(\.helloReceived).map { $0.info() }
        let shown: [PeerInfo]
        if session.role == .client && session.group && !groupMembers.isEmpty {
            shown = groupMembers.filter { $0.name != Prefs.shared.deviceName || $0.id == "host" }
        } else {
            shown = direct
        }
        session.peers = direct.isEmpty ? [] : shown
        if !direct.isEmpty { session.status = String(localized: "Connected") }
    }

    /// One shared file should arrive once. A second delivery of the same share (the host forwarding it again) is ignored.
    func claimGroupFile(_ key: String, peerId: String) -> Bool {
        guard session.group, !key.isEmpty else { return true }
        if let owner = groupFiles[key] { return owner == peerId }
        groupFiles[key] = peerId
        return true
    }

    func startIncoming(peer: PeerConnection, name: String, size: Int64, mime: String,
                       origin: String, shareKey: String, relay: Bool) -> (TransferItem, URL) {
        let shown = origin.isEmpty ? peer.name : origin
        let item = TransferItem(id: UUID().uuidString, name: name, size: size, mime: mime, direction: .receive,
                                peerId: peer.id, peerName: shown, status: .active,
                                shareKey: shareKey, originName: shown, relay: relay)
        items.append(item)
        let category = FileUtils.categoryOf(mime: mime, name: name)
        let url = AppFiles.uniqueURL(in: AppFiles.folder(for: category), name: name)
        return (item, url)
    }

    func markActive(_ id: String) { update(id) { $0.status = .active } }

    func markFailed(_ id: String, _ error: String) {
        meter.remove(id)
        if let failed = items.first(where: { $0.id == id }), failed.direction == .receive, !failed.shareKey.isEmpty,
           groupFiles[failed.shareKey] == failed.peerId {
            groupFiles.removeValue(forKey: failed.shareKey)
        }
        update(id) {
            $0.status = .failed
            $0.error = error
        }
        AnalyticsService.log(.transferFailed, ["reason": String(error.prefix(100))])
    }

    func markSent(_ item: TransferItem) {
        meter.remove(item.id)
        // A group forward is the same file the host already received. It is not a second share.
        if item.relay { return }
        update(item.id) {
            $0.status = .done
            $0.transferred = $0.size
        }
        HistoryStore.shared.add(name: item.name, size: item.size, mime: item.mime, sent: true, peer: item.peerName, url: nil)
        AnalyticsService.log(.fileSent, [
            "category": item.mime.split(separator: "/").first.map(String.init) ?? "other",
            "bytes": AnalyticsService.bytes(item.size)
        ])
        finished(sent: true, bytes: item.size)
    }

    func markReceived(from peer: PeerConnection, item: TransferItem, url: URL) {
        meter.remove(item.id)
        update(item.id) {
            $0.status = .done
            $0.transferred = $0.size
            $0.resultURL = url
        }
        if session.group && !item.shareKey.isEmpty {
            items.removeAll { $0.id != item.id && $0.shareKey == item.shareKey && $0.direction == .receive }
        }
        HistoryStore.shared.add(name: item.name, size: item.size, mime: item.mime, sent: false, peer: item.peerName, url: url)
        AnalyticsService.log(.fileReceived, [
            "category": item.mime.split(separator: "/").first.map(String.init) ?? "other",
            "bytes": AnalyticsService.bytes(item.size)
        ])
        finished(sent: false, bytes: item.size)
        if Prefs.shared.saveToPhotos { PhotoSaver.saveIfMedia(url) }

        // Group relay: the host forwards every file to all other members.
        if session.role == .host && session.group && Prefs.shared.groupRelay && !item.relay
            && (StoreService.shared.isPremium || item.size <= AppConfig.freeFileLimit) {
            for p in peers.values where p.id != peer.id {
                let out = TransferItem(id: UUID().uuidString, name: item.name, size: item.size, mime: item.mime,
                                       direction: .send, peerId: p.id, peerName: p.name,
                                       shareKey: item.shareKey, originName: item.originName, relay: true)
                p.enqueueFile(out, url: url)
            }
        }
    }

    private func finished(sent: Bool, bytes: Int64) {
        finishedCount += 1
        AdsManager.shared.markTaskDone()
        AnalyticsService.log(.transferDone, [
            "direction": sent ? "send" : "receive",
            "bytes": AnalyticsService.bytes(bytes)
        ])
        Task { await FirestoreService.shared.addTransferStats(sent: sent, bytes: bytes) }
        PushService.shared.askAfterFirstTaskIfNeeded()
    }

    private func update(_ id: String, _ change: (inout TransferItem) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i])
    }

    // MARK: - Progress ticker

    private func startTicker() {
        ticker?.invalidate()
        lastTick = Date()
        let t = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let now = Date()
                let secs = max(0.05, now.timeIntervalSince(self.lastTick))
                self.lastTick = now
                let (pending, bytes) = self.meter.snapshot()
                let rate = Double(bytes) / secs
                self.smoothed = self.smoothed == 0 ? rate : self.smoothed * 0.6 + rate * 0.4
                if bytes == 0 && self.smoothed < 1024 { self.smoothed = 0 }
                if !pending.isEmpty {
                    for i in self.items.indices where self.items[i].status == .active {
                        if let b = pending[self.items[i].id] { self.items[i].transferred = b }
                    }
                }
                self.session.speed = self.smoothed
                self.tickCount += 1
                // Host: pick up new addresses (e.g. Personal Hotspot turned on) every ~3 s.
                if self.session.role == .host, self.tickCount % 10 == 0, let info = self.session.hostInfo {
                    let lan = NetUtils.lanIPs()
                    if lan != info.ips {
                        var updated = info
                        updated.ips = lan
                        updated.ip = NetUtils.wifiIP ?? lan.first ?? "0.0.0.0"
                        self.session.hostInfo = updated
                        self.updateNetworkHint()
                    }
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    // MARK: - Lifetime

    var hasActiveWork: Bool {
        session.active && !session.disconnected && items.contains { $0.status == .active || $0.status == .waiting }
    }

    func clearError() { session.error = nil }

    func stop() {
        let all = Array(peers.values)
        peers.removeAll()
        all.forEach { $0.sayBye() }
        listener?.cancel()
        listener = nil
        ticker?.invalidate()
        ticker = nil
        meter.reset()
        groupFiles = [:]
        groupMembers = []
        smoothed = 0
        cleanupNetwork()
        endKeepAlive()
        session = SessionState()
    }

    private func cleanupNetwork() {
        if let ssid = joinedSSID {
            HotspotJoiner.leave(ssid: ssid)
            joinedSSID = nil
        }
    }

    /// Keeps the screen awake (setting) and asks iOS for extra time if the app goes to the background mid-transfer.
    private func beginKeepAlive() {
        UIApplication.shared.isIdleTimerDisabled = Prefs.shared.keepScreenOn
        if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "transfer") { [weak self] in
                Task { @MainActor in self?.endBackgroundTask() }
            }
        }
    }

    private func endKeepAlive() {
        UIApplication.shared.isIdleTimerDisabled = false
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
}

/// Thread-safe "first caller wins" flag.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// Joins the offline hotspot an Android phone shows in its QR code.
enum HotspotJoiner {
    static func join(ssid: String, passphrase: String?) async throws {
        let config: NEHotspotConfiguration
        if let passphrase, !passphrase.isEmpty {
            config = NEHotspotConfiguration(ssid: ssid, passphrase: passphrase, isWEP: false)
        } else {
            config = NEHotspotConfiguration(ssid: ssid)
        }
        config.joinOnce = true
        do {
            try await NEHotspotConfigurationManager.shared.apply(config)
        } catch let error as NSError
            where error.domain == NEHotspotConfigurationErrorDomain
                && error.code == NEHotspotConfigurationError.alreadyAssociated.rawValue {
            return
        } catch let error as NSError
            where error.domain == NEHotspotConfigurationErrorDomain
                && error.code == NEHotspotConfigurationError.userDenied.rawValue {
            throw TransferError.noRoute(String(localized: "You need to allow joining the other phone's Wi-Fi to connect."))
        }
    }

    static func leave(ssid: String) {
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
    }
}

/// Saves received photos / videos to the Photos library when the setting is on (add-only permission).
enum PhotoSaver {
    static func saveIfMedia(_ url: URL) {
        let mime = FileUtils.mimeOf(url.lastPathComponent)
        guard mime.hasPrefix("image/") || mime.hasPrefix("video/") else { return }
        Task { _ = await save(url) }
    }

    @discardableResult
    static func save(_ url: URL) async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return false }
        let isVideo = FileUtils.mimeOf(url.lastPathComponent).hasPrefix("video/")
        do {
            try await PHPhotoLibrary.shared().performChanges {
                if isVideo {
                    _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                } else {
                    _ = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
                }
            }
            return true
        } catch {
            Log.e("Save to Photos failed", error)
            return false
        }
    }
}
