import SwiftUI
import Photos

struct SafeboxView: View {
    @EnvironmentObject private var vault: Vault

    var body: some View {
        Group {
            if !vault.isSetUp {
                VaultSetupView()
            } else if !vault.isUnlocked {
                VaultUnlockView()
            } else {
                VaultContentView()
            }
        }
        .navigationTitle(Text("Safebox"))
        .navigationBarTitleDisplayMode(.inline)
        // Match Android: leaving Safebox (back, tab change, etc.) always re-locks.
        .onDisappear { vault.lock() }
    }
}

// MARK: - PIN pad

struct PinPad: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey? = nil
    var length = 4...8
    var error: String?
    var showsHeader = true
    let onDone: (String) -> Void
    @State private var pin = ""

    var body: some View {
        VStack(spacing: 22) {
            if showsHeader {
                BrandIconBox(systemName: "lock.fill", size: 64)
                Text(title).font(.title3.bold())
                if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center) }
            }
            HStack(spacing: 14) {
                ForEach(0..<max(length.lowerBound, pin.count), id: \.self) { i in
                    Circle().fill(i < pin.count ? Brand.cyan3 : Color.gray.opacity(0.3)).frame(width: 14, height: 14)
                }
            }
            .accessibilityElement()
            .accessibilityLabel(Text("\(pin.count) digits entered"))
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 14) {
                ForEach(["1", "2", "3", "4", "5", "6", "7", "8", "9", "", "0", "⌫"], id: \.self) { k in
                    if k.isEmpty {
                        Color.clear.frame(height: 64)
                    } else {
                        Button {
                            if k == "⌫" { if !pin.isEmpty { pin.removeLast() } }
                            else if pin.count < length.upperBound { pin.append(k) }
                        } label: {
                            Text(k).font(.title.weight(.medium)).frame(width: 72, height: 64)
                                .background(Brand.card, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(k == "⌫" ? Text("Delete") : Text(k))
                    }
                }
            }
            .frame(maxWidth: 300)
            Button("OK") {
                let value = pin
                pin = ""
                onDone(value)
            }
            .buttonStyle(BrandButtonStyle())
            .disabled(pin.count < length.lowerBound)
        }
        .padding()
    }
}

struct VaultSetupView: View {
    @EnvironmentObject private var vault: Vault
    @State private var first: String?
    @State private var error: String?

    var body: some View {
        ScrollView {
            if first == nil {
                PinPad(title: "Create a PIN", subtitle: "4 to 8 digits. You'll use it to open your Safebox.", error: error) { pin in
                    first = pin
                    error = nil
                }
            } else {
                PinPad(title: "Confirm your PIN", error: error) { pin in
                    if pin == first {
                        do { try vault.setup(pin: pin) } catch { self.error = error.localizedDescription }
                    } else {
                        error = String(localized: "PINs don't match. Try again.")
                        first = nil
                    }
                }
            }
        }
    }
}

struct VaultUnlockView: View {
    @EnvironmentObject private var vault: Vault
    @State private var error: String?
    @State private var usePattern = false
    @State private var showRecovery = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                BrandIconBox(systemName: "lock.fill", size: 64).padding(.top, 8)
                Text(usePattern ? "Draw your pattern" : "Enter PIN").font(.title3.bold())
                Text(usePattern ? "Connect at least 4 dots" : "Enter 4 to 8 digits")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 22)
                Group {
                    if usePattern {
                        PatternLockView { pattern in
                            if !vault.unlockWithPattern(pattern) { error = String(localized: "Wrong pattern") }
                        }
                        .frame(width: 280, height: 280)
                        if let error { Text(error).foregroundStyle(.red) }
                    } else {
                        PinPad(title: "Enter PIN", showsHeader: false, error: error) { pin in
                            if !vault.unlock(pin: pin) { error = String(localized: "Wrong PIN") }
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 420, alignment: .top)
                if usePattern {
                    Button("Use PIN instead") { usePattern = false; error = nil }
                } else if vault.hasPattern {
                    Button("Use pattern") { usePattern = true; error = nil }
                }
                if vault.biometricEnabled, let name = Vault.biometryName {
                    Button { Task { await tryBiometrics(automatic: false) } } label: {
                        Label("Unlock with \(name)", systemImage: name == "Face ID" ? "faceid" : "touchid")
                    }
                }
                if vault.hasQuestions {
                    Button("Forgot PIN?") { showRecovery = true }.font(.footnote)
                }
            }
            .padding(.bottom)
        }
        .task {
            // Offer biometrics, but ignore an instant "success" right after the phone unlock
            // (same guard as Android) so Safebox still truly asks every visit.
            if vault.biometricEnabled && Vault.biometryName != nil {
                await tryBiometrics(automatic: true)
            }
        }
        .sheet(isPresented: $showRecovery) { RecoveryView() }
    }

    private func tryBiometrics(automatic: Bool) async {
        let started = Date()
        let ok = await vault.unlockWithBiometrics()
        if automatic && ok && Date().timeIntervalSince(started) < 0.4 {
            vault.lockNow()
            return
        }
        if !ok && !automatic { error = String(localized: "Biometrics failed. Use your PIN.") }
    }
}

/// 3×3 pattern lock. Reports the dot sequence like "0-4-8".
struct PatternLockView: View {
    var minimum = 4
    let onDone: (String) -> Void
    @State private var path: [Int] = []
    @State private var finger: CGPoint?

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let step = side / 3
            let centers = (0..<9).map { CGPoint(x: step * (CGFloat($0 % 3) + 0.5), y: step * (CGFloat($0 / 3) + 0.5)) }
            ZStack {
                Path { p in
                    guard let first = path.first else { return }
                    p.move(to: centers[first])
                    path.dropFirst().forEach { p.addLine(to: centers[$0]) }
                    if let finger { p.addLine(to: finger) }
                }
                .stroke(Brand.cyan3, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                ForEach(0..<9, id: \.self) { i in
                    Circle().fill(path.contains(i) ? Brand.cyan3 : Color.gray.opacity(0.35))
                        .frame(width: 22, height: 22)
                        .position(centers[i])
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    finger = v.location
                    for (i, c) in centers.enumerated() where !path.contains(i) {
                        if hypot(c.x - v.location.x, c.y - v.location.y) < step * 0.3 { path.append(i) }
                    }
                }
                .onEnded { _ in
                    finger = nil
                    if path.count >= minimum { onDone(path.map(String.init).joined(separator: "-")) }
                    path = []
                })
        }
        .accessibilityLabel(Text("Pattern lock"))
    }
}

struct RecoveryView: View {
    @EnvironmentObject private var vault: Vault
    @Environment(\.dismiss) private var dismiss
    @State private var answers: [Int: String] = [:]
    @State private var verified = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if verified {
                    PinPad(title: "Set a new PIN") { pin in
                        vault.resetPin(pin)
                        dismiss()
                    }
                } else {
                    Form {
                        ForEach(vault.questionIndexes(), id: \.self) { q in
                            Section(Vault.questions[q]) {
                                TextField("Answer", text: Binding(get: { answers[q] ?? "" }, set: { answers[q] = $0 }))
                                    .textInputAutocapitalization(.never)
                            }
                        }
                        if let error { Text(error).foregroundStyle(.red) }
                        Button("Check answers") {
                            if vault.checkQuestions(answers.map { ($0.key, $0.value) }) { verified = true }
                            else { error = String(localized: "Those answers don't match.") }
                        }
                    }
                }
            }
            .navigationTitle(Text("Reset PIN"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

// MARK: - Contents

struct VaultContentView: View {
    @EnvironmentObject private var vault: Vault
    @EnvironmentObject private var prefs: Prefs
    @EnvironmentObject private var store: StoreService
    @State private var showMedia = false
    @State private var showFiles = false
    @State private var showUnlock = false
    @State private var showSettings = false
    @State private var busy = false
    @State private var error: String?
    @State private var preview: URL?
    @State private var tick = 0

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 6)]

    private var room: Int { DayUnlock.vault() ? Int.max : max(0, DayUnlock.freeVault - vault.count) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("\(vault.count) files").font(.headline)
                    Spacer()
                    if !DayUnlock.vault() {
                        Text("\(vault.count)/\(DayUnlock.freeVault) free").font(.caption).foregroundStyle(.secondary)
                    }
                    UnlockPill(state: store.isPremium ? .premium : (DayUnlock.vault() ? .unlockedToday : .locked))
                        .onTapGesture { if !DayUnlock.vault() { showUnlock = true } }
                }
                .id(tick)
                if !vault.hasQuestions {
                    SectionCard {
                        Label("Add recovery questions", systemImage: "questionmark.circle.fill").font(.headline)
                        Text("If you forget your PIN, answering them lets you set a new one.").font(.caption).foregroundStyle(.secondary)
                        Button("Set up") { showSettings = true }.padding(.top, 6)
                    }
                }
                if busy { ProgressView("Encrypting…") }
                if let error { ErrorBanner(text: error) { self.error = nil } }
                if vault.entries.isEmpty {
                    EmptyStateView(icon: "lock.shield", title: "Your Safebox is empty",
                                   message: "Hide private photos, videos and files. They're encrypted on this iPhone.")
                }
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(vault.entries) { e in
                        VaultTile(entry: e)
                            .onTapGesture { open(e) }
                            .contextMenu {
                                Button { open(e) } label: { Label("Open", systemImage: "eye") }
                                Button { restore(e, toPhotos: false) } label: { Label("Restore to Files", systemImage: "folder") }
                                if e.category == .photos || e.category == .videos {
                                    Button { restore(e, toPhotos: true) } label: { Label("Restore to Photos", systemImage: "photo") }
                                }
                                Button(role: .destructive) { vault.delete(e) } label: { Label("Delete forever", systemImage: "trash") }
                            }
                    }
                }
            }
            .padding()
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button { addTapped { showMedia = true } } label: { Label("Add photos & videos", systemImage: "photo.on.rectangle") }
                    Button { addTapped { showFiles = true } } label: { Label("Add other files", systemImage: "doc") }
                } label: { Image(systemName: "plus.circle.fill") }
                    .accessibilityLabel(Text("Add"))
                Menu {
                    Button { showSettings = true } label: { Label("Safebox settings", systemImage: "gearshape") }
                    Button { vault.lockNow() } label: { Label("Lock now", systemImage: "lock") }
                } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel(Text("More"))
            }
        }
        .sheet(isPresented: $showMedia) {
            MediaPicker(withLibrary: true) { items, ids in
                Task { await addAll(items.map(\.url), photoIDs: ids) }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showFiles) {
            DocumentPicker { urls in Task { await addAll(urls, photoIDs: []) } }.ignoresSafeArea()
        }
        .sheet(isPresented: $showUnlock) {
            UnlockSheet(title: "More room in Safebox",
                        message: "The free Safebox holds 10 files. Watch a short video for unlimited room today, or get Premium.",
                        icon: "lock.shield.fill", perks: ["Unlimited files today", "Lasts until midnight"]) {
                DayUnlock.grantVault()
                tick += 1
            }
        }
        .sheet(isPresented: $showSettings) { VaultSettingsView() }
        .fullScreenCover(item: $preview, onDismiss: { vault.suppressAutoLock = false }) { url in
            QuickLookView(urls: [url]).ignoresSafeArea()
        }
        .onChange(of: preview) { url in
            vault.suppressAutoLock = url != nil
        }
    }

    private func addTapped(_ go: () -> Void) {
        if room <= 0 { showUnlock = true } else { go() }
    }

    private func addAll(_ urls: [URL], photoIDs: [String]) async {
        busy = true
        defer { busy = false }
        var added = 0
        for url in urls.prefix(room) {
            do {
                try await vault.add(url)
                try? FileManager.default.removeItem(at: url) // staged copy
                added += 1
            } catch {
                self.error = error.localizedDescription
            }
        }
        if urls.count > room { showUnlock = true }
        AdsManager.shared.markTaskDone()
        // Optionally remove the originals from Photos (iOS asks the user to confirm).
        if prefs.deleteAfterHide && !photoIDs.isEmpty && added > 0 {
            let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            guard status == .authorized || status == .limited else { return }
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: Array(photoIDs.prefix(added)), options: nil)
            try? await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(assets) }
        }
    }

    private func open(_ e: VaultEntry) {
        Task {
            do { preview = try await vault.openTemp(e) } catch { self.error = error.localizedDescription }
        }
    }

    private func restore(_ e: VaultEntry, toPhotos: Bool) {
        Task {
            do {
                let url = try await vault.restore(e)
                if toPhotos, await PhotoSaver.save(url) { try? FileManager.default.removeItem(at: url) }
                Router.shared.showToast(toPhotos ? String(localized: "Restored to Photos") : String(localized: "Restored to Files › Restored"))
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct VaultTile: View {
    let entry: VaultEntry
    var body: some View {
        VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 14).fill(entry.category.color.opacity(0.15))
                .frame(height: 84)
                .overlay(Image(systemName: entry.category.icon).font(.title).foregroundStyle(entry.category.color))
            Text(entry.name).font(.caption2).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

struct VaultSettingsView: View {
    @EnvironmentObject private var vault: Vault
    @EnvironmentObject private var prefs: Prefs
    @Environment(\.dismiss) private var dismiss
    @State private var changing = false
    @State private var oldPin: String?
    @State private var message: String?
    @State private var drawingPattern = false
    @State private var q1 = 0
    @State private var q2 = 1
    @State private var a1 = ""
    @State private var a2 = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let name = Vault.biometryName {
                        Toggle("Unlock with \(name)", isOn: $vault.biometricEnabled)
                    }
                    Toggle("Remove originals from Photos after hiding", isOn: $prefs.deleteAfterHide)
                    Button("Change PIN") { changing = true }
                    if vault.hasPattern {
                        Button("Remove pattern", role: .destructive) { vault.clearPattern() }
                    } else {
                        Button("Set a pattern") { drawingPattern = true }
                    }
                    if let message { Text(message).foregroundStyle(.secondary) }
                } footer: {
                    Text("Safebox files are encrypted and stay on this iPhone. They are not included in backups.")
                }
                Section("Recovery questions") {
                    Picker("Question 1", selection: $q1) { ForEach(0..<Vault.questions.count, id: \.self) { Text(Vault.questions[$0]).tag($0) } }
                    TextField("Answer", text: $a1)
                    Picker("Question 2", selection: $q2) { ForEach(0..<Vault.questions.count, id: \.self) { Text(Vault.questions[$0]).tag($0) } }
                    TextField("Answer", text: $a2)
                    Button("Save questions") {
                        vault.saveQuestions([(q1, a1), (q2, a2)])
                        message = String(localized: "Recovery questions saved.")
                        a1 = ""; a2 = ""
                    }
                    .disabled(a1.isEmpty || a2.isEmpty || q1 == q2)
                }
            }
            .navigationTitle(Text("Safebox settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $changing) {
                if oldPin == nil {
                    PinPad(title: "Current PIN") { oldPin = $0 }
                } else {
                    PinPad(title: "New PIN") { new in
                        message = vault.changePin(old: oldPin ?? "", new: new) ? String(localized: "PIN changed.") : String(localized: "Wrong PIN")
                        oldPin = nil
                        changing = false
                    }
                }
            }
            .sheet(isPresented: $drawingPattern) {
                VStack(spacing: 16) {
                    Text("Draw a pattern (4+ dots)").font(.headline).padding(.top, 24)
                    PatternLockView { pattern in
                        vault.setPattern(pattern)
                        message = String(localized: "Pattern saved.")
                        drawingPattern = false
                    }
                    .frame(width: 280, height: 280)
                }
                .presentationDetents([.medium])
            }
        }
    }
}
