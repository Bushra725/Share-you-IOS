import Foundation
import UniformTypeIdentifiers
import SwiftUI

/// File categories. Received files are sorted into one folder per category, like Android's
/// Download/ZapShare/<Photos|Videos|Music|Documents|Files>.
enum FileCategory: String, CaseIterable, Identifiable, Hashable, Codable {
    case photos, videos, music, documents, archives, apps, other

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .photos: return "Photos"
        case .videos: return "Videos"
        case .music: return "Music"
        case .documents: return "Documents"
        case .archives: return "Archives"
        case .apps: return "Apps"
        case .other: return "Files"
        }
    }

    /// Folder name under Documents/Received.
    var folder: String {
        switch self {
        case .photos: return "Photos"
        case .videos: return "Videos"
        case .music: return "Music"
        case .documents: return "Documents"
        case .apps: return "Apps"
        case .archives, .other: return "Files"
        }
    }

    var icon: String {
        switch self {
        case .photos: return "photo.fill"
        case .videos: return "film.fill"
        case .music: return "music.note"
        case .documents: return "doc.text.fill"
        case .archives: return "doc.zipper"
        case .apps: return "app.badge.fill"
        case .other: return "doc.fill"
        }
    }

    var color: Color {
        switch self {
        case .photos: return Brand.catPhoto
        case .videos: return Brand.catVideo
        case .music: return Brand.catMusic
        case .documents: return Brand.catDocs
        case .archives: return Brand.catDownload
        case .apps: return Brand.catApps
        case .other: return Brand.catCyan
        }
    }

    /// Categories shown in the file manager (APKs can't be used on iOS but may still be received).
    static var browsable: [FileCategory] { [.photos, .videos, .music, .documents, .archives, .other] }
}

enum FileUtils {
    static func mimeOf(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        if ext == "apk" { return "application/vnd.android.package-archive" }
        return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }

    static func normalizeMime(_ name: String, _ mime: String) -> String {
        let m = mime.trimmingCharacters(in: .whitespaces).lowercased()
        if m.isEmpty || m == "application/octet-stream" || m == "*/*" { return mimeOf(name) }
        return m
    }

    static func categoryOf(mime: String, name: String) -> FileCategory {
        let m = normalizeMime(name, mime)
        let ext = (name as NSString).pathExtension.lowercased()
        if m.hasPrefix("image/") { return .photos }
        if m.hasPrefix("video/") { return .videos }
        if m.hasPrefix("audio/") { return .music }
        if ext == "apk" || m == "application/vnd.android.package-archive" { return .apps }
        if ["zip", "rar", "7z", "tar", "gz", "bz2", "xz", "apks", "xapk"].contains(ext) { return .archives }
        let docExt = ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "rtf", "csv", "md",
                      "pages", "numbers", "key", "odt", "ods", "odp", "epub", "html", "htm", "json", "xml"]
        if docExt.contains(ext) || m.hasPrefix("text/") || m == "application/pdf" { return .documents }
        return .other
    }

    /// Removes characters that are not allowed in file names and stops path tricks like "../".
    static func safeName(_ raw: String) -> String {
        var name = (raw as NSString).lastPathComponent
        let bad = CharacterSet(charactersIn: "\\/:*?\"<>|\0").union(.controlCharacters)
        name = name.components(separatedBy: bad).joined(separator: "_")
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { name = "file" }
        if name.count > 180 {
            let ext = (name as NSString).pathExtension
            let stem = String((name as NSString).deletingPathExtension.prefix(160))
            name = ext.isEmpty ? stem : "\(stem).\(ext)"
        }
        return name
    }

    static func formatSize(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(max(bytes, 0)) B" }
        let units = ["KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var i = -1
        repeat { value /= 1024; i += 1 } while value >= 1024 && i < units.count - 1
        return String(format: value < 10 ? "%.2f %@" : "%.1f %@", value, units[i])
    }

    static func formatSpeed(_ bytesPerSecond: Double) -> String {
        "\(formatSize(Int64(bytesPerSecond)))/s"
    }

    static func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds.rounded())
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    static func fileSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey])
        return Int64(values?.fileSize ?? values?.totalFileAllocatedSize ?? 0)
    }
}

/// The app's own storage. Everything under Documents is visible in the Files app.
enum AppFiles {
    static let fm = FileManager.default

    static var documents: URL { fm.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var received: URL { documents.appendingPathComponent("Received", isDirectory: true) }
    static var fromPC: URL { received.appendingPathComponent("PC", isDirectory: true) }
    static var converted: URL { documents.appendingPathComponent("Converted", isDirectory: true) }
    static var restored: URL { documents.appendingPathComponent("Restored", isDirectory: true) }
    static var imported: URL { documents.appendingPathComponent("Imported", isDirectory: true) }
    static var appSupport: URL { fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0] }
    /// Staging area for files picked to send (copied out of Photos / Files). Cleared on launch.
    static var outbox: URL { fm.temporaryDirectory.appendingPathComponent("Outbox", isDirectory: true) }

    static func prepareFolders() {
        for url in [received, converted, imported, appSupport, outbox] {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        clearOutboxIfOld()
    }

    static func folder(for category: FileCategory) -> URL {
        let url = received.appendingPathComponent(category.folder, isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// "photo.jpg" → "photo (1).jpg" when the name is taken.
    static func uniqueURL(in dir: URL, name: String) -> URL {
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = FileUtils.safeName(name)
        var url = dir.appendingPathComponent(safe)
        let stem = (safe as NSString).deletingPathExtension
        let ext = (safe as NSString).pathExtension
        var n = 1
        while fm.fileExists(atPath: url.path) || fm.fileExists(atPath: url.path + ".part") {
            let candidate = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            url = dir.appendingPathComponent(candidate)
            n += 1
        }
        return url
    }

    /// Path relative to Documents (stored in history so it survives app updates, where the container path changes).
    static func relativePath(_ url: URL) -> String? {
        let base = documents.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(base) else { return nil }
        return String(path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func resolve(relative: String) -> URL { documents.appendingPathComponent(relative) }

    struct Storage { let total: Int64; let free: Int64; var used: Int64 { max(0, total - free) } }

    static func storage() -> Storage {
        let values = try? documents.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        let total = Int64(values?.volumeTotalCapacity ?? 0)
        let free = values?.volumeAvailableCapacityForImportantUsage ?? 0
        return Storage(total: total, free: free)
    }

    private static func clearOutboxIfOld() {
        guard let items = try? fm.contentsOfDirectory(at: outbox, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-6 * 3600)
        for item in items {
            let date = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if date < cutoff { try? fm.removeItem(at: item) }
        }
    }

    /// Copies an external file (share sheet, Files, Photos) into a private staging folder.
    static func stage(_ source: URL, name: String? = nil) throws -> URL {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let dir = outbox.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(FileUtils.safeName(name ?? source.lastPathComponent))
        try fm.copyItem(at: source, to: dest)
        return dest
    }
}

/// A file on this iPhone (inside the app's Documents folder).
struct LocalFile: Identifiable, Hashable {
    let url: URL
    let name: String
    let size: Int64
    let modified: Date
    let isDirectory: Bool

    var id: URL { url }
    var mime: String { FileUtils.mimeOf(name) }
    var category: FileCategory { FileUtils.categoryOf(mime: mime, name: name) }

    init(url: URL) {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey, .creationDateKey])
        self.url = url
        self.name = url.lastPathComponent
        self.size = Int64(values?.fileSize ?? 0)
        self.modified = values?.contentModificationDate ?? values?.creationDate ?? Date.distantPast
        self.isDirectory = values?.isDirectory ?? false
    }

    var shareItem: ShareItem { ShareItem(url: url, name: name, size: size, mime: mime) }
}

enum FileScanner {
    /// All files under Documents (recursive), newest first. Runs off the main thread.
    static func allFiles(under root: URL = AppFiles.documents) async -> [LocalFile] {
        await Task.detached(priority: .userInitiated) {
            let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey, .creationDateKey]
            guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
            var out: [LocalFile] = []
            for case let url as URL in e {
                let f = LocalFile(url: url)
                if !f.isDirectory, !f.name.hasSuffix(".part") { out.append(f) }
            }
            return out.sorted { $0.modified > $1.modified }
        }.value
    }

    static func contents(of dir: URL) -> [LocalFile] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        return urls.map(LocalFile.init(url:)).filter { !$0.name.hasSuffix(".part") }
    }
}
