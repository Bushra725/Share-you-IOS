import SwiftUI
import PhotosUI

// MARK: - Send: pick files

struct SendView: View {
    @EnvironmentObject private var selection: SelectionStore
    @EnvironmentObject private var store: StoreService
    @EnvironmentObject private var router: Router
    @State private var showLimit = false

    var body: some View {
        List {
            Section {
                FileSourceButtons()
            }
            if selection.importing {
                Section { HStack { ProgressView(); Text("Preparing files…") } }
            }
            Section {
                if selection.items.isEmpty {
                    EmptyStateView(icon: "tray", title: "No files selected", message: "Pick photos, videos, music or any file to send.")
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(selection.items) { item in
                        HStack(spacing: 12) {
                            FileThumb(url: item.url, name: item.name)
                            VStack(alignment: .leading) {
                                Text(item.name).lineLimit(1)
                                Text(FileUtils.formatSize(item.size)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions { Button(role: .destructive) { selection.remove(item) } label: { Label("Remove", systemImage: "trash") } }
                    }
                }
            } header: {
                if !selection.items.isEmpty {
                    Text("\(selection.items.count) file(s) selected") + Text(" • \(FileUtils.formatSize(selection.totalSize))")
                }
            }
        }
        .navigationTitle(Text("Select files"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !selection.items.isEmpty {
                ToolbarItem(placement: .cancellationAction) { Button("Clear") { selection.clear() } }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                if !store.isPremium && !selection.oversized.isEmpty { showLimit = true }
                else { router.push(.connect(group: false)) }
            } label: {
                Text("NEXT").frame(maxWidth: .infinity)
            }
            .buttonStyle(BrandButtonStyle())
            .disabled(selection.items.isEmpty || selection.importing)
            .opacity(selection.items.isEmpty ? 0.5 : 1)
            .padding()
            .background(.bar)
        }
        .alert(Text("File over 1 GB"), isPresented: $showLimit) {
            Button("Go Premium") { router.paywall() }
            Button("Remove large files", role: .destructive) { selection.removeOversized() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Free plan sends files up to 1 GB each. Upgrade to Premium to send \(FileUtils.formatSize(selection.oversized.first?.size ?? 0)).")
        }
    }
}

/// Photos / Files / Share you files buttons, used by Send and "Send more".
struct FileSourceButtons: View {
    @EnvironmentObject private var selection: SelectionStore
    @State private var showMedia = false
    @State private var showFiles = false
    @State private var showLocal = false

    var body: some View {
        Button { showMedia = true } label: { Label("Photos & videos", systemImage: "photo.on.rectangle.angled") }
            .sheet(isPresented: $showMedia) {
                MediaPicker { items, _ in selection.add(items) }
                    .ignoresSafeArea(edges: .bottom)
                    .stablePickerSheet()
            }
        Button { showFiles = true } label: { Label("Any file (Files app)", systemImage: "folder") }
            .sheet(isPresented: $showFiles) {
                DocumentPicker { urls in
                    let staged = urls.compactMap { try? AppFiles.stage($0) }
                    selection.add(staged.map { ShareItem(url: $0) })
                }
                .ignoresSafeArea(edges: .bottom)
                .stablePickerSheet()
            }
        Button { showLocal = true } label: { Label("Share you files (received, music, documents)", systemImage: "tray.full") }
            .sheet(isPresented: $showLocal) {
                NavigationStack { LocalFilePicker() }
                    .stablePickerSheet()
            }
    }
}

/// Pick files that are already inside Share you (received files, converted files, music…).
struct LocalFilePicker: View {
    @EnvironmentObject private var selection: SelectionStore
    @Environment(\.dismiss) private var dismiss
    @State private var files: [LocalFile] = []
    @State private var category: FileCategory?
    @State private var loading = true

    var body: some View {
        List {
            Picker("Type", selection: $category) {
                Text("All").tag(FileCategory?.none)
                ForEach(FileCategory.browsable) { Text($0.title).tag(FileCategory?.some($0)) }
            }
            .pickerStyle(.menu)
            if loading { ProgressView() }
            ForEach(files.filter { category == nil || $0.category == category }) { f in
                let item = f.shareItem
                Button { selection.toggle(item) } label: {
                    HStack(spacing: 12) {
                        FileThumb(url: f.url, name: f.name)
                        VStack(alignment: .leading) {
                            Text(f.name).lineLimit(1).foregroundStyle(.primary)
                            Text(FileUtils.formatSize(f.size)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: selection.contains(item) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(Brand.cyan3)
                    }
                }
                .accessibilityAddTraits(selection.contains(item) ? .isSelected : [])
            }
            if !loading && files.isEmpty {
                EmptyStateView(icon: "tray", title: "No files yet", message: "Files you receive will show up here.")
            }
        }
        .navigationTitle(Text("Share you files"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .task {
            files = await FileScanner.allFiles()
            loading = false
        }
    }
}

// MARK: - Send: connect to the receiver

struct ConnectView: View {
    let group: Bool
    @EnvironmentObject private var transfer: TransferManager
    @EnvironmentObject private var selection: SelectionStore
    @State private var mode = 0
    @State private var manualIP = ""
    @State private var sentSelection = false

    var body: some View {
        Group {
            if transfer.session.role == .client && (transfer.session.connected || transfer.session.disconnected) {
                TransferSessionView(group: group)
            } else {
                connectContent
            }
        }
        .navigationTitle(group ? Text("Join group") : Text("Send"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if !group { transfer.startBrowsing() } }
        .onDisappear { transfer.stopBrowsing() }
        .onChange(of: transfer.session.connected) { connected in
            guard connected, !sentSelection, !selection.items.isEmpty else { return }
            sentSelection = true
            transfer.send(selection.items)
            selection.clear()
        }
    }

    private var connectContent: some View {
        VStack(spacing: 16) {
            Picker("", selection: $mode) {
                Text("Scan QR code").tag(0)
                if !group { Text("Nearby").tag(1) }
                Text("Enter IP").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            if transfer.session.busy {
                ProgressView(transfer.session.status).padding()
            }
            if let error = transfer.session.error {
                ErrorBanner(text: error) { transfer.clearError() }.padding(.horizontal)
            }

            switch mode {
            case 0:
                ScannerScreen { code in
                    guard let info = HostInfo.parse(code) else {
                        Router.shared.showToast(String(localized: "This is not a Share you QR code"))
                        return
                    }
                    Task { await transfer.connect(info) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 24))
                .padding(.horizontal)
                Text("Ask the receiver to tap Receive and scan the QR code on their screen. Works with Android and iPhone.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal)
            case 1:
                List {
                    Section {
                        if transfer.nearby.isEmpty {
                            HStack { ProgressView(); Text("Looking for nearby devices…") }
                        }
                        ForEach(transfer.nearby) { d in
                            Button { Task { await transfer.connect(nearby: d) } } label: {
                                Label(d.name, systemImage: "iphone.radiowaves.left.and.right")
                            }
                        }
                    } footer: {
                        Text("Phones on the same Wi-Fi with Receive open appear here. iPhones also find each other without Wi-Fi.")
                    }
                }
            default:
                Form {
                    Section {
                        TextField("192.168.1.20", text: $manualIP)
                            .keyboardType(.decimalPad)
                            .textContentType(.none)
                        Button("Connect") { Task { await transfer.connect(ip: manualIP) } }
                            .disabled(manualIP.split(separator: ".").count != 4)
                    } footer: {
                        Text("Use the address shown under the QR code on the receiving phone.")
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top)
    }
}

// MARK: - Receive (host)

struct ReceiveView: View {
    var group = false
    @EnvironmentObject private var transfer: TransferManager

    var body: some View {
        Group {
            if transfer.session.role == .host && !transfer.session.peers.isEmpty && !group {
                TransferSessionView(group: false)
            } else {
                HostQRView(group: group)
            }
        }
        .navigationTitle(group ? Text("Group share") : Text("Receive"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if transfer.session.role != .host || transfer.session.group != group {
                transfer.startHost(group: group)
            }
        }
    }
}

struct HostQRView: View {
    let group: Bool
    @EnvironmentObject private var transfer: TransferManager
    @EnvironmentObject private var prefs: Prefs

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                AvatarBubble(index: prefs.avatar, size: 72, ring: true).padding(.top)
                Text(prefs.deviceName).font(.title3.bold())
                if transfer.session.busy {
                    ProgressView(transfer.session.status)
                } else if let info = transfer.session.hostInfo {
                    QRCodeView(text: info.toQR())
                        .frame(width: 240, height: 240)
                        .padding(14)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 24))
                        .shadow(color: .black.opacity(0.08), radius: 10)
                    Text(transfer.session.status).font(.headline).multilineTextAlignment(.center)
                    if info.ip != "0.0.0.0" {
                        Text("IP: \(info.ip)").font(.footnote.monospaced()).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                if let hint = transfer.session.networkHint {
                    ErrorBanner(text: hint)
                }
                if let error = transfer.session.error {
                    ErrorBanner(text: error) { transfer.clearError() }
                    Button("Try again") { transfer.startHost(group: group) }.buttonStyle(.borderedProminent)
                }
                if group {
                    GroupMembersCard()
                    if !transfer.session.peers.isEmpty {
                        TransferSessionView(group: true, embedded: true)
                            .frame(height: 380)
                    }
                }
                Text("On the other phone open Share you, tap Send, pick files and scan this code.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding()
        }
        .background(Brand.background)
    }
}

struct GroupMembersCard: View {
    @EnvironmentObject private var transfer: TransferManager
    @EnvironmentObject private var store: StoreService
    @State private var showUnlock = false
    @State private var tick = 0

    var body: some View {
        let unlocked = DayUnlock.groupLarge()
        SectionCard {
            HStack {
                Text("Members").font(.headline)
                Spacer()
                UnlockPill(state: store.isPremium ? .premium : (unlocked ? .unlockedToday : .locked))
                    .onTapGesture { if !unlocked { showUnlock = true } }
            }
            Text("\(transfer.session.peers.count) of \(unlocked ? DayUnlock.fullGroupMembers : DayUnlock.freeGroupMembers) joined")
                .font(.subheadline).foregroundStyle(.secondary).padding(.top, 2)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(transfer.session.peers) { p in
                        VStack {
                            AvatarBubble(index: p.avatar, size: 44)
                            Text(p.name).font(.caption2).lineLimit(1).frame(width: 64)
                        }
                    }
                }
                .padding(.top, 8)
            }
        }
        .id(tick)
        .sheet(isPresented: $showUnlock) {
            UnlockSheet(title: "Bigger groups today",
                        message: "Free groups hold 3 members. Watch one short video to allow 8 members until midnight.",
                        icon: "person.3.fill",
                        perks: ["Up to 8 members", "Lasts until midnight"]) {
                DayUnlock.grantGroup()
                tick += 1
            }
        }
    }
}

// MARK: - Group share entry

struct GroupShareView: View {
    @EnvironmentObject private var router: Router

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                BrandIconBox(systemName: "person.3.fill", size: 72).padding(.top, 24)
                Text("Share with several phones at once").font(.title3.bold()).multilineTextAlignment(.center)
                Text("One phone creates the group, the others scan its QR code. Every file is forwarded to all members.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button { router.push(.receive(group: true)) } label: {
                    Label("Create group", systemImage: "qrcode").frame(maxWidth: .infinity)
                }
                .buttonStyle(BrandButtonStyle())
                Button { router.push(.connect(group: true)) } label: {
                    Label("Join group", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).controlSize(.large)
            }
            .padding()
        }
        .navigationTitle(Text("Group share"))
    }
}

// MARK: - Live session

struct TransferSessionView: View {
    let group: Bool
    var embedded = false
    @EnvironmentObject private var transfer: TransferManager
    @EnvironmentObject private var selection: SelectionStore
    @EnvironmentObject private var ads: AdsManager
    @Environment(\.dismiss) private var dismiss
    @State private var showMore = false
    @State private var preview: URL?

    var body: some View {
        VStack(spacing: 0) {
            header
            if let error = transfer.session.error {
                ErrorBanner(text: error) { transfer.clearError() }.padding(.horizontal).padding(.top, 8)
            }
            List {
                ForEach(transfer.items.reversed()) { item in
                    TransferRow(item: item)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if item.status == .done, let url = item.resultURL { preview = url }
                        }
                }
                if transfer.items.isEmpty {
                    EmptyStateView(icon: "arrow.left.arrow.right", title: "Connected",
                                   message: "Send files from either phone. They appear here.")
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            if !embedded { bottomBar }
        }
        .sheet(isPresented: $showMore, onDismiss: {
            if !selection.items.isEmpty {
                transfer.send(selection.items)
                selection.clear()
            }
        }) {
            NavigationStack {
                List { FileSourceButtons() }
                    .navigationTitle(Text("Send more"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Send") { showMore = false } } }
                    .overlay(alignment: .bottom) {
                        if selection.importing { ProgressView().padding() }
                        else if !selection.items.isEmpty { Text("\(selection.items.count) file(s) selected").padding() }
                    }
            }
            .presentationDetents([.medium])
        }
        .fullScreenCover(item: $preview) { url in
            QuickLookView(urls: [url]).ignoresSafeArea()
        }
        .onDisappear {
            guard !embedded else { return }
            if transfer.finishedCount > 0 { ads.tryShow(group ? .groupDone : .transferDone) }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: -10) {
                ForEach(transfer.session.peers.prefix(6)) { p in AvatarBubble(index: p.avatar, size: 44, ring: true) }
            }
            Text(transfer.session.peers.map(\.name).joined(separator: ", "))
                .font(.headline).lineLimit(2).multilineTextAlignment(.center)
            HStack(spacing: 6) {
                Circle().fill(transfer.session.disconnected ? Color.red : Color.green).frame(width: 8, height: 8)
                Text(transfer.session.status).font(.subheadline)
                if transfer.session.speed > 0 {
                    Text("• \(FileUtils.formatSpeed(transfer.session.speed))").font(.subheadline.monospacedDigit())
                }
            }
            .foregroundStyle(Brand.navy)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Brand.gradient)
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button { showMore = true } label: { Label("Send more", systemImage: "plus").frame(maxWidth: .infinity) }
                .buttonStyle(BrandButtonStyle())
                .disabled(transfer.session.disconnected)
            Button(role: .destructive) {
                transfer.stop()
                dismiss()
            } label: { Label("Disconnect", systemImage: "xmark").frame(maxWidth: .infinity) }
                .buttonStyle(.bordered).controlSize(.large)
        }
        .padding()
        .background(.bar)
    }
}

extension URL: Identifiable { public var id: String { absoluteString } }

struct TransferRow: View {
    let item: TransferItem
    var body: some View {
        HStack(spacing: 12) {
            FileThumb(url: item.status == .done ? item.resultURL : nil, name: item.name)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: item.direction == .send ? "arrow.up" : "arrow.down")
                    Text(item.direction == .send ? "To \(item.peerName)" : "From \(item.peerName)")
                    Text("• \(FileUtils.formatSize(item.size))")
                }
                .font(.caption).foregroundStyle(.secondary)
                if item.status == .active || item.status == .waiting {
                    ProgressView(value: item.progress).tint(Brand.cyan3)
                }
                if let error = item.error, item.status == .failed {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            statusIcon
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text("\(Int(item.progress * 100)) percent"))
    }

    @ViewBuilder private var statusIcon: some View {
        switch item.status {
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        case .active: Text("\(Int(item.progress * 100))%").font(.caption.monospacedDigit())
        case .waiting: Image(systemName: "clock").foregroundStyle(.secondary)
        }
    }
}

extension View {
    /// One full-height detent. A downward swipe dismisses the picker instead of stretching it over the status bar.
    func stablePickerSheet() -> some View {
        modifier(StablePickerSheet())
    }
}

private struct StablePickerSheet: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.4, *) {
            content
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationContentInteraction(.scrolls)
        } else {
            content
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }
}
