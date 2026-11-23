import SwiftUI
import UIKit

/// Holds the PC-share session so the screen can be left (e.g. to pick files) and come back.
@MainActor
final class PcShare: ObservableObject {
    static let shared = PcShare()

    @Published private(set) var running = false
    @Published private(set) var url: String?
    @Published private(set) var altURLs: [String] = []
    @Published private(set) var token = ""
    @Published private(set) var shared: [ShareItem] = []
    @Published private(set) var received: [ShareItem] = []
    @Published private(set) var incoming: [IncomingPCFile] = []
    @Published private(set) var log: [String] = []
    @Published var error: String?
    @Published private(set) var transfersDone = 0

    private var server: PcServer?
    private var refresher: Timer?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    func start() async {
        stop()
        let token = (0..<6).map { _ in String(Int.random(in: 0...9)) }.joined()
        let s = PcServer(token: token)
        s.snapshot = { [weak self] in
            // Called from the server queue: read a thread-safe copy.
            self?.threadSafeSnapshot() ?? ([], [], "iPhone")
        }
        s.onReceived = { [weak self] url, name, size in
            Task { @MainActor in self?.didReceive(url: url, name: name, size: size) }
        }
        s.onReceiveProgress = { [weak self] name, written, total in
            Task { @MainActor in self?.noteIncoming(name: name, written: written, total: total) }
        }
        s.onLog = { [weak self] msg in
            Task { @MainActor in self?.append(msg) }
        }
        do {
            try await s.start()
            server = s
            self.token = token
            running = true
            error = nil
            refreshAddresses()
            updateSnapshot()
            UIApplication.shared.isIdleTimerDisabled = true
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "pc") { [weak self] in
                Task { @MainActor in self?.endBackgroundTask() }
            }
            let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshAddresses() }
            }
            RunLoop.main.add(t, forMode: .common)
            refresher = t
            AnalyticsService.log(.pcStart)
        } catch {
            self.error = String(localized: "Could not open the PC page. \(error.localizedDescription)")
        }
    }

    func stop() {
        server?.stop()
        server = nil
        refresher?.invalidate()
        refresher = nil
        running = false
        url = nil
        altURLs = []
        incoming = []
        UIApplication.shared.isIdleTimerDisabled = false
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    /// Re-reads this iPhone's addresses (e.g. after Personal Hotspot is turned on).
    func refreshAddresses() {
        guard running else { return }
        let all = NetUtils.lanIPs()
        let best = NetUtils.wifiIP ?? NetUtils.hotspotIP ?? all.first
        url = best.map(pageURL)
        altURLs = all.filter { $0 != best }.map(pageURL)
    }

    private func pageURL(_ ip: String) -> String { "http://\(ip):\(AppConfig.pcPort)/?k=\(token)" }

    func addShared(_ items: [ShareItem]) {
        for item in items where !shared.contains(where: { $0.id == item.id }) { shared.append(item) }
        updateSnapshot()
    }

    func removeShared(_ item: ShareItem) {
        shared.removeAll { $0.id == item.id }
        updateSnapshot()
    }

    private func noteIncoming(name: String, written: Int64, total: Int64) {
        if let i = incoming.firstIndex(where: { $0.name == name }) {
            let previous = incoming[i].fraction
            let next = total > 0 ? min(0.99, Double(written) / Double(total)) : 0
            if total > 0, next - previous < 0.01 { return }
            if total <= 0, written - incoming[i].written < 64 * 1024 { return }
            incoming[i].written = written
            incoming[i].total = total
        } else {
            incoming.append(IncomingPCFile(name: name, written: written, total: total))
        }
    }

    private func didReceive(url: URL, name: String, size: Int64) {
        incoming.removeAll { $0.name == name }
        received.append(ShareItem(url: url, name: name, size: size))
        AnalyticsService.log(.pcUpload, ["bytes": AnalyticsService.bytes(size)])
        HistoryStore.shared.add(name: name, size: size, mime: FileUtils.mimeOf(name), sent: false, peer: "PC", url: url)
        LocalNotificationService.shared.fileReceived(name: name, from: "PC")
        transfersDone += 1
        AdsManager.shared.markTaskDone()
        updateSnapshot()
    }

    private func append(_ msg: String) {
        log.insert(msg, at: 0)
        if log.count > 50 { log.removeLast(log.count - 50) }
        if msg.hasPrefix(String(localized: "PC downloaded")) {
            transfersDone += 1
            AnalyticsService.log(.pcDownload)
        }
    }

    // MARK: thread-safe snapshot for the server queue

    nonisolated(unsafe) private let snapLock = NSLock()
    nonisolated(unsafe) private var snap: ([PcServer.FileEntry], [PcServer.FileEntry], String) = ([], [], "iPhone")

    private func updateSnapshot() {
        let s = shared.map { PcServer.FileEntry(url: $0.url, name: $0.name, size: $0.size, mime: $0.mime) }
        let r = received.map { PcServer.FileEntry(url: $0.url, name: $0.name, size: $0.size, mime: $0.mime) }
        let name = Prefs.shared.deviceName
        snapLock.lock()
        snap = (s, r, name)
        snapLock.unlock()
    }

    nonisolated private func threadSafeSnapshot() -> (shared: [PcServer.FileEntry], received: [PcServer.FileEntry], name: String) {
        snapLock.lock(); defer { snapLock.unlock() }
        return (snap.0, snap.1, snap.2)
    }
}

struct IncomingPCFile: Identifiable {
    let id: String
    var name: String
    var written: Int64
    var total: Int64
    init(name: String, written: Int64, total: Int64) {
        self.id = name
        self.name = name
        self.written = written
        self.total = total
    }
    var fraction: Double { total > 0 ? min(0.99, Double(written) / Double(total)) : 0 }
}

struct PcShareView: View {
    @EnvironmentObject private var pc: PcShare
    @EnvironmentObject private var ads: AdsManager
    @State private var showSources = false
    @State private var pendingAdd: [ShareItem] = []
    @State private var preview: URL?
    @State private var altOpen = false

    var body: some View {
        List {
            Section {
                if pc.running, let url = pc.url {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("On your computer, open this address in any browser:").font(.subheadline)
                        Text(url).font(.title3.monospaced().bold()).foregroundStyle(Brand.cyanInk)
                            .textSelection(.enabled)
                        HStack {
                            Text("Access code:").foregroundStyle(.secondary)
                            Text(pc.token).font(.headline.monospaced())
                        }
                        Button {
                            AnalyticsService.click("copy_address", screen: "connect_pc")
                            UIPasteboard.general.string = url
                        } label: { Label("Copy address", systemImage: "doc.on.doc") }
                    }
                    .padding(.vertical, 4)
                    if !pc.altURLs.isEmpty {
                        DisclosureGroup("Page doesn't open? Try these", isExpanded: Binding(get: { altOpen }, set: { on in
                            if on { AnalyticsService.click("alt_addresses", screen: "connect_pc") }
                            altOpen = on
                        })) {
                            ForEach(pc.altURLs, id: \.self) { Text($0).font(.footnote.monospaced()).textSelection(.enabled) }
                        }
                    }
                } else if pc.running {
                    ErrorBanner(text: String(localized: "No Wi-Fi address yet. Join the same Wi-Fi as the PC, or turn on Personal Hotspot and connect the PC to it."))
                } else {
                    HStack { ProgressView(); Text("Starting…") }
                }
                if let error = pc.error {
                    ErrorBanner(text: error)
                    Button("Try again") {
                        AnalyticsService.click("retry", screen: "connect_pc")
                        Task { await pc.start() }
                    }
                }
            } header: {
                Text("Connect to PC")
            } footer: {
                Text("The PC and this iPhone must be on the same Wi-Fi. No Wi-Fi? Turn on Personal Hotspot on this iPhone (Settings › Personal Hotspot) and join it from the PC. Keep this screen open while sharing.")
            }

            Section {
                Button {
                    AnalyticsService.click("add_files", screen: "connect_pc")
                    showSources = true
                } label: { Label("Add files for the PC", systemImage: "plus.circle.fill") }
                ForEach(pc.shared) { item in
                    Button { preview = item.url } label: {
                        HStack {
                            FileThumb(url: item.url, name: item.name, size: 36)
                            Text(item.name).lineLimit(1).foregroundStyle(.primary)
                            Spacer()
                            Text(FileUtils.formatSize(item.size)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions { Button(role: .destructive) {
                        AnalyticsService.click("remove_shared", screen: "connect_pc")
                        pc.removeShared(item)
                    } label: { Label("Remove", systemImage: "trash") } }
                }
            } header: { Text("Shared with the PC") }

            if !pc.incoming.isEmpty {
                Section("Receiving") {
                    ForEach(pc.incoming) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(item.name).lineLimit(1)
                                Spacer()
                                Text(item.total > 0 ? "\(Int(item.fraction * 100))%" : FileUtils.formatSize(item.written))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            if item.total > 0 {
                                ProgressView(value: item.fraction).tint(Brand.cyan3)
                            } else {
                                ProgressView().tint(Brand.cyan3)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityValue(Text("\(Int(item.fraction * 100)) percent"))
                    }
                }
            }

            Section {
                if pc.received.isEmpty && pc.incoming.isEmpty {
                    Text("Drag files onto the page on your PC to send them here.").foregroundStyle(.secondary)
                }
                ForEach(pc.received) { item in
                    Button { preview = item.url } label: {
                        HStack {
                            FileThumb(url: item.url, name: item.name, size: 36)
                            Text(item.name).lineLimit(1).foregroundStyle(.primary)
                            Spacer()
                            Text(FileUtils.formatSize(item.size)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: { Text("Received from PC") }

            if !pc.log.isEmpty {
                Section("Activity") {
                    ForEach(Array(pc.log.prefix(10).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.footnote)
                    }
                }
            }
        }
        .navigationTitle(Text("Connect PC"))
        .navigationBarTitleDisplayMode(.inline)
        .task { if !pc.running { await pc.start() } }
        .onDisappear {
            if pc.transfersDone > 0 { ads.tryShow(.pcDone) }
        }
        .toolbar {
            if pc.running {
                ToolbarItem(placement: .primaryAction) {
                    Button("Stop", role: .destructive) {
                        AnalyticsService.click("stop_server", screen: "connect_pc")
                        pc.stop()
                    }
                }
            }
        }
        .sheet(isPresented: $showSources, onDismiss: {
            let picked = SelectionStore.shared.items
            if !picked.isEmpty {
                pc.addShared(picked)
                SelectionStore.shared.clear()
            }
        }) {
            NavigationStack {
                List { FileSourceButtons() }
                    .navigationTitle(Text("Add files"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showSources = false } } }
            }
            .presentationDetents([.medium])
        }
        .fullScreenCover(item: $preview) { url in
            QuickLookView(urls: [url]).ignoresSafeArea()
        }
    }
}
