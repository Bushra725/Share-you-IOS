import SwiftUI
import UniformTypeIdentifiers

/// Files tab: storage, categories, folder browser, large files, import.
struct FilesView: View {
    @EnvironmentObject private var router: Router
    @State private var files: [LocalFile] = []
    @State private var showImport = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                StorageCard { router.push(.browser(AppFiles.documents)) }
                SectionCard {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                        ForEach(FileCategory.browsable) { c in
                            let list = files.filter { $0.category == c }
                            Button { router.push(.category(c)) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: c.icon).foregroundStyle(c.color)
                                        .frame(width: 40, height: 40).background(c.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
                                    VStack(alignment: .leading) {
                                        Text(c.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                        Text("\(list.count) files").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(10)
                                .background(Brand.background, in: RoundedRectangle(cornerRadius: 14))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                SectionCard(padding: 4) {
                    menuRow("folder.fill", "Browse") { router.push(.browser(AppFiles.documents)) }
                    Divider()
                    menuRow("externaldrive.fill.badge.exclamationmark", "Large files") { router.push(.largeFiles) }
                    Divider()
                    menuRow("square.and.arrow.down.fill", "Import from Files") { showImport = true }
                }
                Text("Everything here is also in the Files app: On My iPhone › Share you.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                AdBanner()
            }
            .padding()
        }
        .background(Brand.background)
        .navigationTitle(Text("Files"))
        .task { files = await FileScanner.allFiles() }
        .refreshable { files = await FileScanner.allFiles() }
        .sheet(isPresented: $showImport) {
            DocumentPicker { urls in
                for u in urls {
                    let dest = AppFiles.uniqueURL(in: AppFiles.imported, name: u.lastPathComponent)
                    try? FileManager.default.copyItem(at: u, to: dest)
                }
                Task { files = await FileScanner.allFiles() }
            }
            .ignoresSafeArea()
        }
    }

    private func menuRow(_ icon: String, _ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon).foregroundStyle(Brand.cyan3).frame(width: 30)
                Text(title).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(12)
        }
    }
}

struct StorageCard: View {
    var action: () -> Void
    private let st = AppFiles.storage()

    var body: some View {
        Button(action: action) {
            SectionCard {
                HStack(spacing: 12) {
                    BrandIconBox(systemName: "internaldrive.fill")
                    VStack(alignment: .leading) {
                        Text("Internal storage").font(.headline).foregroundStyle(.primary)
                        Text("\(FileUtils.formatSize(st.used)) used of \(FileUtils.formatSize(st.total))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                let frac = st.total > 0 ? Double(st.used) / Double(st.total) : 0
                ProgressView(value: frac).tint(frac > 0.85 ? .red : Brand.cyan3).padding(.top, 10)
                Text("\(FileUtils.formatSize(st.free)) free").font(.caption2).foregroundStyle(.secondary).padding(.top, 4)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Shared file actions

/// Open (preview), share, rename, delete, move to Safebox — one place so every list behaves the same.
struct FileActionsModifier: ViewModifier {
    @Binding var preview: URL?
    @Binding var shareURL: URL?
    @Binding var renaming: LocalFile?
    @State private var newName = ""
    var onChange: () -> Void

    func body(content: Content) -> some View {
        content
            .fullScreenCover(item: $preview) { url in QuickLookView(urls: [url]).ignoresSafeArea() }
            .sheet(item: $shareURL) { url in ShareSheet(items: [url]).presentationDetents([.medium, .large]) }
            .alert(Text("Rename"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Save") {
                    if let f = renaming, !newName.isEmpty {
                        let dest = f.url.deletingLastPathComponent().appendingPathComponent(FileUtils.safeName(newName))
                        try? FileManager.default.moveItem(at: f.url, to: dest)
                        onChange()
                    }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
            .onChange(of: renaming) { f in newName = f?.name ?? "" }
    }
}

struct FileRow: View {
    let file: LocalFile
    var body: some View {
        HStack(spacing: 12) {
            if file.isDirectory {
                Image(systemName: "folder.fill").font(.title2).foregroundStyle(Brand.cyan3).frame(width: 44, height: 44)
            } else {
                FileThumb(url: file.url, name: file.name)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).lineLimit(1)
                Group {
                    if file.isDirectory {
                        Text(file.modified, style: .date)
                    } else {
                        Text("\(FileUtils.formatSize(file.size)) • \(file.modified.formatted(date: .abbreviated, time: .omitted))")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Category

struct CategoryFilesView: View {
    let category: FileCategory
    @EnvironmentObject private var ads: AdsManager
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var selection: SelectionStore
    @EnvironmentObject private var music: MusicController
    @State private var files: [LocalFile] = []
    @State private var preview: URL?
    @State private var shareURL: URL?
    @State private var renaming: LocalFile?
    @State private var selecting = false
    @State private var picked = Set<URL>()
    @State private var confirmDelete = false

    var body: some View {
        List {
            if files.isEmpty { EmptyStateView(icon: category.icon, title: "No files yet", message: "Files you receive will show up here.") }
            ForEach(files) { f in
                HStack {
                    if selecting {
                        Image(systemName: picked.contains(f.url) ? "checkmark.circle.fill" : "circle").foregroundStyle(Brand.cyan3)
                    }
                    FileRow(file: f)
                }
                .contentShape(Rectangle())
                .onTapGesture { tap(f) }
                .swipeActions {
                    Button(role: .destructive) { delete([f.url]) } label: { Label("Delete", systemImage: "trash") }
                    Button { shareURL = f.url } label: { Label("Share", systemImage: "square.and.arrow.up") }.tint(Brand.cyan3)
                }
                .contextMenu {
                    Button { shareURL = f.url } label: { Label("Share", systemImage: "square.and.arrow.up") }
                    Button { renaming = f } label: { Label("Rename", systemImage: "pencil") }
                    Button { sendNow([f]) } label: { Label("Send", systemImage: "paperplane") }
                    Button(role: .destructive) { delete([f.url]) } label: { Label("Delete", systemImage: "trash") }
                }
            }
        }
        .navigationTitle(Text(category.title))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(selecting ? "Done" : "Select") { selecting.toggle(); picked.removeAll() }
            }
            if selecting && !picked.isEmpty {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { sendNow(files.filter { picked.contains($0.url) }) } label: { Label("Send", systemImage: "paperplane") }
                    Spacer()
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
                }
            }
        }
        .confirmationDialog(Text("Delete \(picked.count) file(s)?"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { delete(Array(picked)); picked.removeAll(); selecting = false }
        }
        .modifier(FileActionsModifier(preview: $preview, shareURL: $shareURL, renaming: $renaming) { reload() })
        .task { reload() }
    }

    private func reload() {
        Task { files = await FileScanner.allFiles().filter { $0.category == category } }
    }

    private func tap(_ f: LocalFile) {
        if selecting {
            if picked.contains(f.url) { picked.remove(f.url) } else { picked.insert(f.url) }
            return
        }
        if category == .music {
            Task {
                var tracks: [Track] = []
                for file in files { tracks.append(await MusicLibrary.track(for: file.url)) }
                if let i = files.firstIndex(of: f) { music.play(tracks, startAt: i) }
            }
            return
        }
        if category == .videos {
            VideoController.shared.open(.file(f.url))
            return
        }
        preview = f.url
        ads.tryShow(.fileOpen)
    }

    private func sendNow(_ list: [LocalFile]) {
        selection.add(list.map(\.shareItem))
        router.push(.send)
    }

    private func delete(_ urls: [URL]) {
        urls.forEach { try? FileManager.default.removeItem(at: $0) }
        reload()
    }
}

// MARK: - Folder browser (copy / move / rename / delete / new folder / search)

struct FolderBrowserView: View {
    let folder: URL
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var ads: AdsManager
    @State private var items: [LocalFile] = []
    @State private var preview: URL?
    @State private var shareURL: URL?
    @State private var renaming: LocalFile?
    @State private var newFolder = false
    @State private var folderName = ""
    @State private var search = ""
    @State private var results: [LocalFile] = []
    @State private var sortBySize = false
    @StateObject private var clipboard = FileClipboard.shared

    var body: some View {
        List {
            if let clip = clipboard.items.first {
                Section {
                    HStack {
                        Image(systemName: clipboard.move ? "scissors" : "doc.on.doc")
                        Text("\(clipboard.items.count) item(s): \(clip.lastPathComponent)").lineLimit(1)
                        Spacer()
                        Button("Paste here") { clipboard.paste(into: folder); reload() }.buttonStyle(.borderedProminent)
                        Button { clipboard.clear() } label: { Image(systemName: "xmark") }
                    }
                }
            }
            ForEach(search.isEmpty ? sorted(items) : results) { f in
                Group {
                    if f.isDirectory {
                        NavigationLink(value: Route.browser(f.url)) { FileRow(file: f) }
                    } else {
                        FileRow(file: f).contentShape(Rectangle()).onTapGesture {
                            preview = f.url
                            ads.tryShow(.fileOpen)
                        }
                    }
                }
                .contextMenu {
                    if !f.isDirectory { Button { shareURL = f.url } label: { Label("Share", systemImage: "square.and.arrow.up") } }
                    Button { renaming = f } label: { Label("Rename", systemImage: "pencil") }
                    Button { clipboard.set([f.url], move: false) } label: { Label("Copy", systemImage: "doc.on.doc") }
                    Button { clipboard.set([f.url], move: true) } label: { Label("Move", systemImage: "folder") }
                    Button(role: .destructive) {
                        try? FileManager.default.removeItem(at: f.url)
                        reload()
                    } label: { Label("Delete", systemImage: "trash") }
                }
                .swipeActions {
                    Button(role: .destructive) {
                        try? FileManager.default.removeItem(at: f.url)
                        reload()
                    } label: { Label("Delete", systemImage: "trash") }
                }
            }
            if items.isEmpty && search.isEmpty { EmptyStateView(icon: "folder", title: "This folder is empty") }
        }
        .navigationTitle(folder == AppFiles.documents ? Text("Share you") : Text(folder.lastPathComponent))
        .searchable(text: $search, prompt: Text("Search files"))
        .onChange(of: search) { q in
            Task {
                let all = await FileScanner.allFiles(under: folder)
                results = q.isEmpty ? [] : all.filter { $0.name.localizedCaseInsensitiveContains(q) }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { newFolder = true } label: { Label("New folder", systemImage: "folder.badge.plus") }
                    Toggle(isOn: $sortBySize) { Label("Sort by size", systemImage: "arrow.up.arrow.down") }
                } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel(Text("More"))
            }
        }
        .alert(Text("New folder"), isPresented: $newFolder) {
            TextField("Name", text: $folderName)
            Button("Create") {
                let url = folder.appendingPathComponent(FileUtils.safeName(folderName), isDirectory: true)
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                folderName = ""
                reload()
            }
            Button("Cancel", role: .cancel) {}
        }
        .modifier(FileActionsModifier(preview: $preview, shareURL: $shareURL, renaming: $renaming) { reload() })
        .onAppear { reload() }
    }

    private func sorted(_ list: [LocalFile]) -> [LocalFile] {
        list.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return sortBySize ? a.size > b.size : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    private func reload() { items = FileScanner.contents(of: folder) }
}

@MainActor
final class FileClipboard: ObservableObject {
    static let shared = FileClipboard()
    @Published private(set) var items: [URL] = []
    @Published private(set) var move = false

    func set(_ urls: [URL], move: Bool) { items = urls; self.move = move }
    func clear() { items = [] }

    func paste(into dir: URL) {
        let fm = FileManager.default
        for src in items {
            if dir.standardizedFileURL.path.hasPrefix(src.standardizedFileURL.path) { continue } // no folder into itself
            let dest = AppFiles.uniqueURL(in: dir, name: src.lastPathComponent)
            if move { try? fm.moveItem(at: src, to: dest) } else { try? fm.copyItem(at: src, to: dest) }
        }
        items = []
    }
}

// MARK: - Large files

struct LargeFilesView: View {
    @EnvironmentObject private var ads: AdsManager
    @State private var files: [LocalFile] = []
    @State private var picked = Set<URL>()
    @State private var loading = true
    @State private var confirm = false

    var body: some View {
        List {
            Section {
                if loading { ProgressView() }
                if !loading && files.isEmpty { EmptyStateView(icon: "checkmark.seal", title: "No large files", message: "Nothing over 50 MB in Share you.") }
                ForEach(files) { f in
                    HStack {
                        Image(systemName: picked.contains(f.url) ? "checkmark.circle.fill" : "circle").foregroundStyle(Brand.cyan3)
                        FileRow(file: f)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { if picked.contains(f.url) { picked.remove(f.url) } else { picked.insert(f.url) } }
                }
            } footer: {
                Text("Files over 50 MB stored in Share you, largest first. Photos and videos in your library are cleaned in Tools › Clean.")
            }
        }
        .navigationTitle(Text("Large files"))
        .safeAreaInset(edge: .bottom) {
            if !picked.isEmpty {
                Button(role: .destructive) { confirm = true } label: {
                    Text("Delete \(picked.count) file(s) • \(FileUtils.formatSize(files.filter { picked.contains($0.url) }.reduce(0) { $0 + $1.size }))")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.red).controlSize(.large).padding()
            }
        }
        .confirmationDialog(Text("Delete \(picked.count) file(s)?"), isPresented: $confirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                picked.forEach { try? FileManager.default.removeItem(at: $0) }
                picked.removeAll()
                Task { await load() }
                ads.tryShow(.scanCleaned)
            }
        }
        .task { await load() }
    }

    private func load() async {
        files = await FileScanner.allFiles().filter { $0.size >= 50 * 1024 * 1024 }.sorted { $0.size > $1.size }
        loading = false
    }
}
