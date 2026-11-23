import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

@MainActor
final class ConverterViewModel: ObservableObject {
    @Published var op: ConvertOp?
    @Published var inputs: [URL] = []
    @Published var text = ""
    @Published var running = false
    @Published var progress: Double = 0
    @Published var outputs: [URL] = []
    @Published var report: String?
    @Published var error: String?
    @Published var batch = false

    func reset() {
        inputs = []; outputs = []; report = nil; error = nil; progress = 0; text = ""
    }

    func run() async {
        guard let op else { return }
        running = true
        error = nil
        outputs = []
        report = nil
        progress = 0
        defer { running = false }
        AnalyticsService.log(.convertStart, ["op": op.rawValue, "count": max(inputs.count, op.input == .text ? 1 : 0), "batch": batch ? 1 : 0])
        do {
            switch op.input {
            case .text:
                outputs = [try Converters.textToPDF(text)]
            case .images where op.combinesInputs:
                let urls = inputs
                outputs = [try await Task.detached { try Converters.imagesToPDF(urls) }.value]
            case .images:
                for (i, url) in inputs.enumerated() {
                    let out = try await Task.detached { try Converters.convertImage(url, op: op) }.value
                    outputs.append(out)
                    progress = Double(i + 1) / Double(inputs.count)
                }
            case .pdf:
                for url in inputs {
                    let pages = try await Task.detached { try Converters.pdfToImages(url) }.value
                    outputs += pages
                }
            case .media, .video, .audio:
                let total = Double(inputs.count)
                for (i, url) in inputs.enumerated() {
                    let base = Double(i)
                    let (out, rep) = try await Converters.convertMedia(url, op: op) { [weak self] p in
                        Task { @MainActor in self?.progress = (base + p) / total }
                    }
                    outputs.append(out)
                    if let rep { report = (report.map { $0 + "\n" } ?? "") + rep }
                }
            }
            progress = 1
            AnalyticsService.log(.convertDone, ["op": op.rawValue, "count": inputs.count])
            AdsManager.shared.markTaskDone()
            LocalNotificationService.shared.taskFinished(
                String(localized: "Conversion finished"),
                body: String(localized: "Your converted files are ready."),
                route: "tools")
        } catch {
            self.error = error.localizedDescription
            AnalyticsService.log(.convertFailed, ["op": op.rawValue, "reason": error.localizedDescription])
        }
    }
}

struct ConverterView: View {
    @StateObject private var vm = ConverterViewModel()
    @EnvironmentObject private var store: StoreService
    @EnvironmentObject private var ads: AdsManager
    @State private var showMedia = false
    @State private var showFiles = false
    @State private var showUnlock = false
    @State private var preview: URL?
    @State private var share: URL?
    @State private var tick = 0

    private let sections: [(LocalizedStringKey, [ConvertOp])] = [
        ("Images", [.toJPG, .toPNG, .toHEIC, .compressImage, .resizeImage]),
        ("PDF", [.imagesToPDF, .pdfToImages, .textToPDF]),
        ("Audio & video", [.toM4A, .toWAV, .toMP4, .compress720, .compress480, .toGIF])
    ]

    var body: some View {
        List {
            Section {
                let unlocked = DayUnlock.batch()
                Toggle(isOn: Binding(get: { vm.batch }, set: { on in
                    AnalyticsService.click("batch_toggle", screen: "converter", ["on": on ? 1 : 0])
                    if on && !unlocked {
                        AnalyticsService.click("unlock_batch", screen: "converter")
                        showUnlock = true
                    } else { vm.batch = on }
                })) {
                    HStack {
                        Text("Batch mode (many files at once)")
                        UnlockPill(state: store.isPremium ? .premium : (unlocked ? .unlockedToday : .locked))
                    }
                }
                .id(tick)
            }
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                Section(header: Text(section.0)) {
                    ForEach(section.1) { op in
                        Button {
                            AnalyticsService.click("op_select", screen: "converter", ["op": op.rawValue])
                            vm.reset()
                            vm.op = op
                        } label: {
                            Label(op.title, systemImage: op.icon).foregroundStyle(.primary)
                        }
                    }
                }
            }
            Section { AdBanner() }.listRowBackground(Color.clear)
        }
        .navigationTitle(Text("Converter"))
        .sheet(item: $vm.op) { op in
            NavigationStack { jobView(op).trackScreen("convert_job") }
        }
        .sheet(isPresented: $showUnlock) {
            UnlockSheet(title: "Batch mode", message: "Convert many files in one go. Watch one short video to unlock it until midnight.",
                        icon: "square.stack.3d.up.fill", perks: ["Convert many files at once", "Lasts until midnight"]) {
                DayUnlock.grantBatch()
                AnalyticsService.log(.featureUnlock, ["feature": "batch_convert"])
                vm.batch = true
                tick += 1
            }
        }
    }

    @ViewBuilder
    private func jobView(_ op: ConvertOp) -> some View {
        Form {
            Section {
                Label(op.title, systemImage: op.icon).font(.headline)
            }
            if op.input == .text {
                Section("Text") {
                    TextEditor(text: $vm.text).frame(minHeight: 180)
                }
            } else {
                Section {
                    ForEach(vm.inputs, id: \.self) { url in
                        HStack { FileThumb(url: url, name: url.lastPathComponent, size: 36); Text(url.lastPathComponent).lineLimit(1) }
                    }
                    if op.input == .images || op.input == .video || op.input == .media {
                        Button {
                            AnalyticsService.click("pick_photos", screen: "convert_job", ["op": op.rawValue])
                            showMedia = true
                        } label: { Label("Choose from Photos", systemImage: "photo.on.rectangle") }
                    }
                    Button {
                        AnalyticsService.click("pick_files", screen: "convert_job", ["op": op.rawValue])
                        showFiles = true
                    } label: { Label("Choose from Files", systemImage: "folder") }
                } header: {
                    allowsMany(op) ? Text("Files") : Text("File")
                }
            }
            Section {
                Button {
                    AnalyticsService.click("convert", screen: "convert_job", ["op": op.rawValue, "count": vm.inputs.count])
                    Task {
                        await vm.run()
                        if vm.error == nil { ads.tryShow(.convertDone) }
                    }
                } label: {
                    HStack {
                        if vm.running { ProgressView() }
                        vm.running ? Text("Converting…") : Text("Convert")
                    }
                }
                .disabled(vm.running || (op.input == .text ? vm.text.isEmpty : vm.inputs.isEmpty))
                if vm.running || vm.progress > 0 { ProgressView(value: vm.progress).tint(Brand.cyan3) }
                if let error = vm.error { Text(error).foregroundStyle(.red) }
                if let report = vm.report { Text(report).font(.footnote.monospaced()) }
            }
            if !vm.outputs.isEmpty {
                Section {
                    ForEach(vm.outputs, id: \.self) { url in
                        HStack {
                            FileThumb(url: url, name: url.lastPathComponent, size: 36)
                            Text(url.lastPathComponent).lineLimit(1)
                            Spacer()
                            Button {
                                AnalyticsService.click("open_result", screen: "convert_job")
                                preview = url
                            } label: { Image(systemName: "eye") }.buttonStyle(.borderless)
                                .accessibilityLabel(Text("Open"))
                            Button {
                                AnalyticsService.click("share_result", screen: "convert_job")
                                share = url
                            } label: { Image(systemName: "square.and.arrow.up") }.buttonStyle(.borderless)
                                .accessibilityLabel(Text("Share"))
                        }
                    }
                    if vm.outputs.contains(where: { let m = FileUtils.mimeOf($0.lastPathComponent); return m.hasPrefix("image/") || m.hasPrefix("video/") }) {
                        Button {
                            AnalyticsService.click("save_photos", screen: "convert_job")
                            Task { for u in vm.outputs { await PhotoSaver.save(u) }; Router.shared.showToast(String(localized: "Saved to Photos")) }
                        } label: { Label("Save to Photos", systemImage: "square.and.arrow.down") }
                    }
                } header: { Text("Done ✓ — saved in Files › Converted") }
            }
        }
        .navigationTitle(Text("Convert"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") {
            AnalyticsService.click("close", screen: "convert_job")
            vm.op = nil
        } } }
        .sheet(isPresented: $showMedia) {
            MediaPicker(filter: op.input == .images ? .images : .videos, limit: allowsMany(op) ? 0 : 1) { items, _ in
                vm.inputs = allowsMany(op) ? vm.inputs + items.map(\.url) : items.map(\.url)
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showFiles) {
            DocumentPicker(types: types(op), multiple: allowsMany(op)) { urls in
                let staged = urls.compactMap { try? AppFiles.stage($0) }
                vm.inputs = allowsMany(op) ? vm.inputs + staged : staged
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(item: $preview) { url in QuickLookView(urls: [url]).ignoresSafeArea() }
        .sheet(item: $share) { url in ShareSheet(items: [url]) }
    }

    private func allowsMany(_ op: ConvertOp) -> Bool { op.combinesInputs || vm.batch }

    private func types(_ op: ConvertOp) -> [UTType] {
        switch op.input {
        case .images: return [.image]
        case .pdf: return [.pdf]
        case .text: return [.plainText]
        case .video: return [.movie]
        case .audio: return [.audio, .movie]
        case .media: return [.audiovisualContent]
        }
    }
}
