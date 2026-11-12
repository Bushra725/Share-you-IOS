import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Files the user picked to send (Android's `Selection`).
@MainActor
final class SelectionStore: ObservableObject {
    static let shared = SelectionStore()
    @Published private(set) var items: [ShareItem] = []
    @Published var importing = false

    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    var oversized: [ShareItem] { items.filter { $0.size > AppConfig.freeFileLimit } }

    func add(_ item: ShareItem) {
        guard !items.contains(where: { $0.id == item.id }) else { return }
        items.append(item)
    }

    func add(_ list: [ShareItem]) { list.forEach(add) }
    func remove(_ item: ShareItem) { items.removeAll { $0.id == item.id } }
    func toggle(_ item: ShareItem) { contains(item) ? remove(item) : add(item) }
    func contains(_ item: ShareItem) -> Bool { items.contains { $0.id == item.id } }
    func clear() { items.removeAll() }
    func removeOversized() { items.removeAll { $0.size > AppConfig.freeFileLimit } }
}

/// Multi-select photo & video picker (PHPicker — no Photos permission needed).
/// Each picked item is copied as a file into the outbox so it can be streamed.
struct MediaPicker: UIViewControllerRepresentable {
    var filter: PHPickerFilter? = nil
    var limit = 0
    /// Pass the shared library to receive asset identifiers (needed to delete originals after hiding in Safebox).
    var withLibrary = false
    let onPicked: ([ShareItem], [String]) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = withLibrary ? PHPickerConfiguration(photoLibrary: .shared()) : PHPickerConfiguration()
        config.selectionLimit = limit
        config.filter = filter
        config.preferredAssetRepresentationMode = .current
        if #available(iOS 15.0, *) { config.selection = .ordered }
        let vc = PHPickerViewController(configuration: config)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: MediaPicker
        init(_ parent: MediaPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.dismiss()
            guard !results.isEmpty else { return }
            let ids = results.compactMap(\.assetIdentifier)
            let onPicked = parent.onPicked
            Task { @MainActor in SelectionStore.shared.importing = true }
            Task {
                var out: [ShareItem] = []
                for r in results {
                    if let item = await Self.copy(r.itemProvider) { out.append(item) }
                }
                await MainActor.run {
                    SelectionStore.shared.importing = false
                    onPicked(out, ids)
                }
            }
        }

        /// Copies the file the provider offers (original HEIC / MOV, etc.) into the outbox.
        nonisolated static func copy(_ provider: NSItemProvider) async -> ShareItem? {
            let preferred = [UTType.movie, UTType.image].map(\.identifier)
            guard let type = provider.registeredTypeIdentifiers.first(where: { id in
                preferred.contains { UTType(id)?.conforms(to: UTType($0)!) ?? false }
            }) ?? provider.registeredTypeIdentifiers.first else { return nil }
            return await withCheckedContinuation { c in
                _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                    guard let url else { c.resume(returning: nil); return }
                    let ext = url.pathExtension.isEmpty ? (UTType(type)?.preferredFilenameExtension ?? "dat") : url.pathExtension
                    let base = provider.suggestedName ?? url.deletingPathExtension().lastPathComponent
                    let name = FileUtils.safeName("\(base).\(ext)")
                    if let staged = try? AppFiles.stage(url, name: name) {
                        c.resume(returning: ShareItem(url: staged))
                    } else {
                        c.resume(returning: nil)
                    }
                }
            }
        }
    }
}

/// Files-app picker (any file type, multi-select). Files are copied (`asCopy`) into the app's inbox.
struct DocumentPicker: UIViewControllerRepresentable {
    var types: [UTType] = [.item]
    var multiple = true
    let onPicked: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        vc.allowsMultipleSelection = multiple
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    @MainActor final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPicked: ([URL]) -> Void
        init(onPicked: @escaping ([URL]) -> Void) { self.onPicked = onPicked }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onPicked(urls) }
    }
}

/// Folder picker (for "Export to…" style actions).
struct FolderPicker: UIViewControllerRepresentable {
    let onPicked: (URL) -> Void
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        vc.delegate = context.coordinator
        return vc
    }
    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }
    @MainActor final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPicked: (URL) -> Void
        init(onPicked: @escaping (URL) -> Void) { self.onPicked = onPicked }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPicked(url) }
        }
    }
}
