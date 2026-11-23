import Foundation
import Photos
import UIKit

/// Cleaner (iOS version of Android's CleanRepository): duplicate & similar photos, screenshots,
/// large videos and Share you's own cache. Deleting from Photos moves items to "Recently Deleted".
@MainActor
final class PhotoCleaner: ObservableObject {
    struct AssetGroup: Identifiable { let id = UUID(); let assets: [PHAsset] }
    struct LargeVideo: Identifiable { let asset: PHAsset; let size: Int64; var id: String { asset.localIdentifier } }

    @Published private(set) var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published private(set) var scanning = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var duplicates: [AssetGroup] = []
    @Published private(set) var similar: [AssetGroup] = []
    @Published private(set) var screenshots: [PHAsset] = []
    @Published private(set) var largeVideos: [LargeVideo] = []
    @Published private(set) var junkBytes: Int64 = 0
    @Published var selected = Set<String>()
    @Published private(set) var scanned = false

    /// Bytes per asset (from PHAssetResource), cached during the scan.
    private var sizes: [String: Int64] = [:]

    func requestAccess() async {
        status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    func size(of asset: PHAsset) -> Int64 {
        if let s = sizes[asset.localIdentifier] { return s }
        let s = Self.fileSize(asset)
        sizes[asset.localIdentifier] = s
        return s
    }

    nonisolated static func fileSize(_ asset: PHAsset) -> Int64 {
        let resources = PHAssetResource.assetResources(for: asset)
        let main = resources.first { $0.type == .photo || $0.type == .video || $0.type == .fullSizePhoto || $0.type == .fullSizeVideo } ?? resources.first
        return (main?.value(forKey: "fileSize") as? NSNumber)?.int64Value ?? 0
    }

    var selectedBytes: Int64 {
        let all = duplicates.flatMap(\.assets) + similar.flatMap(\.assets) + screenshots + largeVideos.map(\.asset)
        var seen = Set<String>()
        return all.filter { selected.contains($0.localIdentifier) && seen.insert($0.localIdentifier).inserted }
            .reduce(0) { $0 + size(of: $1) }
    }

    // MARK: Scan

    func scan() async {
        guard status == .authorized || status == .limited else { return }
        scanning = true
        progress = 0
        selected = []
        junkBytes = Self.junkSize()

        // Screenshots
        let shotOptions = PHFetchOptions()
        shotOptions.predicate = NSPredicate(format: "(mediaSubtypes & %d) != 0", PHAssetMediaSubtype.photoScreenshot.rawValue)
        shotOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        screenshots = Self.list(PHAsset.fetchAssets(with: .image, options: shotOptions))

        // Large videos (> 100 MB)
        let vids = Self.list(PHAsset.fetchAssets(with: .video, options: nil))
        let bigVideos: [LargeVideo] = await Task.detached(priority: .userInitiated) {
            vids.map { LargeVideo(asset: $0, size: PhotoCleaner.fileSize($0)) }
                .filter { $0.size > 100 * 1024 * 1024 }
                .sorted { $0.size > $1.size }
        }.value
        largeVideos = bigVideos
        bigVideos.forEach { sizes[$0.asset.localIdentifier] = $0.size }

        // Duplicates & similar: perceptual hash (dHash) of the newest 3000 photos, compared with neighbours in time.
        let photoOptions = PHFetchOptions()
        photoOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        photoOptions.predicate = NSPredicate(format: "(mediaSubtypes & %d) == 0", PHAssetMediaSubtype.photoScreenshot.rawValue)
        let all = Self.list(PHAsset.fetchAssets(with: .image, options: photoOptions))
        let photos = Array(all.suffix(3000))
        var hashes: [UInt64?] = []
        hashes.reserveCapacity(photos.count)
        for (i, a) in photos.enumerated() {
            hashes.append(await Self.dHash(a))
            if i % 25 == 0 { progress = Double(i) / Double(max(photos.count, 1)) }
        }
        var dup: [AssetGroup] = []
        var sim: [AssetGroup] = []
        var used = Set<Int>()
        for i in photos.indices where !used.contains(i) {
            guard let h = hashes[i], let d1 = photos[i].creationDate else { continue }
            var exact = [photos[i]]
            var near = [photos[i]]
            var j = i + 1
            // Compare with the next photos taken within 2 minutes.
            while j < photos.count, let d2 = photos[j].creationDate, d2.timeIntervalSince(d1) < 120 {
                if !used.contains(j), let hj = hashes[j] {
                    let dist = (h ^ hj).nonzeroBitCount
                    if dist == 0 && photos[j].pixelWidth == photos[i].pixelWidth && photos[j].pixelHeight == photos[i].pixelHeight {
                        exact.append(photos[j]); used.insert(j)
                    } else if dist <= 6 {
                        near.append(photos[j]); used.insert(j)
                    }
                }
                j += 1
            }
            if exact.count > 1 { dup.append(AssetGroup(assets: exact)) }
            if near.count > 1 { sim.append(AssetGroup(assets: near)) }
        }
        duplicates = dup
        similar = sim
        progress = 1
        scanning = false
        scanned = true
        AnalyticsService.log(.cleanScan, [
            "duplicates": duplicates.count,
            "similar": similar.count,
            "screenshots": screenshots.count,
            "large_videos": largeVideos.count
        ])
    }

    nonisolated private static func list(_ r: PHFetchResult<PHAsset>) -> [PHAsset] {
        var out: [PHAsset] = []
        out.reserveCapacity(r.count)
        r.enumerateObjects { a, _, _ in out.append(a) }
        return out
    }

    /// 64-bit difference hash from a 9×8 grayscale thumbnail.
    nonisolated private static func dHash(_ asset: PHAsset) async -> UInt64? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .fastFormat
        options.resizeMode = .fast
        options.isSynchronous = false
        options.isNetworkAccessAllowed = false
        let image: UIImage? = await withCheckedContinuation { c in
            let once = OnceFlag()
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 64, height: 64),
                                                  contentMode: .aspectFill, options: options) { img, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if !degraded || img == nil { if once.claim() { c.resume(returning: img) } }
            }
        }
        guard let cg = image?.cgImage else { return nil }
        let w = 9, h = 8
        var pixels = [UInt8](repeating: 0, count: w * h)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        var hash: UInt64 = 0
        var bit: UInt64 = 0
        for y in 0..<h {
            for x in 0..<(w - 1) {
                if pixels[y * w + x] > pixels[y * w + x + 1] { hash |= (UInt64(1) << bit) }
                bit += 1
            }
        }
        return hash
    }

    // MARK: Select & delete

    /// Keep the first (best) item of each group and select the rest. Gated by DayUnlock.cleanSelect().
    func smartSelect() {
        for g in duplicates + similar {
            let keep = g.assets.max { ($0.pixelWidth * $0.pixelHeight) < ($1.pixelWidth * $1.pixelHeight) }
            for a in g.assets where a.localIdentifier != keep?.localIdentifier { selected.insert(a.localIdentifier) }
        }
    }

    func selectAll(_ assets: [PHAsset]) {
        assets.forEach { selected.insert($0.localIdentifier) }
    }

    func toggle(_ asset: PHAsset) {
        if selected.contains(asset.localIdentifier) { selected.remove(asset.localIdentifier) }
        else { selected.insert(asset.localIdentifier) }
    }

    /// iOS shows its own confirmation. Returns true when the items were removed.
    func deleteSelected() async -> Bool {
        let ids = Array(selected)
        guard !ids.isEmpty else { return false }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        let bytes = selectedBytes
        do {
            try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(assets) }
            AnalyticsService.log(.cleanDelete, ["count": ids.count, "bytes": AnalyticsService.bytes(bytes)])
            AdsManager.shared.markTaskDone()
            await scan()
            return true
        } catch {
            return false
        }
    }

    // MARK: Junk (Share you's own caches and temp files)

    nonisolated static func junkSize() -> Int64 {
        let dirs = [FileManager.default.temporaryDirectory,
                    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]]
        var total: Int64 = 0
        for d in dirs {
            guard let e = FileManager.default.enumerator(at: d, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
            for case let url as URL in e { total += FileUtils.fileSize(url) }
        }
        return total
    }

    func refreshJunk() async {
        junkBytes = await Task.detached(priority: .utility) { PhotoCleaner.junkSize() }.value
    }

    func cleanJunk() {
        let removed = junkBytes
        AnalyticsService.log(.junkClean, ["bytes": AnalyticsService.bytes(removed)])
        let fm = FileManager.default
        for d in [fm.temporaryDirectory, fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]] {
            for item in (try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? [] {
                try? fm.removeItem(at: item)
            }
        }
        AppFiles.prepareFolders()
        junkBytes = Self.junkSize()
    }
}
