import Foundation

/// One finished transfer (sent or received). Mirrors Android's HistoryStore entries.
struct HistoryEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    let name: String
    let size: Int64
    let mime: String
    let sent: Bool
    let peer: String
    /// Path relative to Documents, for received files (the absolute container path changes between installs).
    let relativePath: String?
    let time: Date

    var url: URL? {
        guard let relativePath else { return nil }
        let url = AppFiles.resolve(relative: relativePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    private static let maxEntries = 500

    @Published private(set) var entries: [HistoryEntry] = []

    private var fileURL: URL { AppFiles.appSupport.appendingPathComponent("history.json") }

    private init() { load() }

    func add(name: String, size: Int64, mime: String, sent: Bool, peer: String, url: URL?) {
        let entry = HistoryEntry(name: name, size: size, mime: mime, sent: sent, peer: peer,
                                 relativePath: url.flatMap(AppFiles.relativePath), time: Date())
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntries { entries.removeLast(entries.count - Self.maxEntries) }
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    var sentBytes: Int64 { entries.filter(\.sent).reduce(0) { $0 + $1.size } }
    var receivedBytes: Int64 { entries.filter { !$0.sent }.reduce(0) { $0 + $1.size } }
    var sentCount: Int { entries.filter(\.sent).count }
    var receivedCount: Int { entries.filter { !$0.sent }.count }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        entries = (try? decoder.decode([HistoryEntry].self, from: data)) ?? []
    }

    private func save() {
        let snapshot = entries
        let url = fileURL
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
