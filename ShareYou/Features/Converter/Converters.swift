import Foundation
import UIKit
import AVFoundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// On-device conversions with Apple frameworks (no FFmpeg needed on iOS).
/// Android's MP3 / OGG / MKV encoders have no iOS system encoder, so those are replaced by M4A / WAV / MP4.
enum ConvertOp: String, CaseIterable, Identifiable {
    // Images
    case toJPG, toPNG, toHEIC, compressImage, resizeImage
    // PDF
    case imagesToPDF, pdfToImages, textToPDF
    // Audio / video
    case toM4A, toWAV, toMP4, compress720, compress480, toGIF

    var id: String { rawValue }

    var title: String {
        switch self {
        case .toJPG: return String(localized: "Image → JPG")
        case .toPNG: return String(localized: "Image → PNG")
        case .toHEIC: return String(localized: "Image → HEIC (small)")
        case .compressImage: return String(localized: "Compress image")
        case .resizeImage: return String(localized: "Resize image (1080 px)")
        case .imagesToPDF: return String(localized: "Images → PDF")
        case .pdfToImages: return String(localized: "PDF → Images")
        case .textToPDF: return String(localized: "Text → PDF")
        case .toM4A: return String(localized: "Video/Audio → M4A (AAC)")
        case .toWAV: return String(localized: "Audio → WAV")
        case .toMP4: return String(localized: "Video → MP4 (H.264)")
        case .compress720: return String(localized: "Compress video (720p)")
        case .compress480: return String(localized: "Compress video (480p, small)")
        case .toGIF: return String(localized: "Video → GIF (first 8 s)")
        }
    }

    var icon: String {
        switch self {
        case .toJPG, .toPNG, .toHEIC: return "photo"
        case .compressImage: return "arrow.down.right.and.arrow.up.left"
        case .resizeImage: return "crop"
        case .imagesToPDF, .textToPDF: return "doc.richtext"
        case .pdfToImages: return "photo.on.rectangle"
        case .toM4A, .toWAV: return "waveform"
        case .toMP4: return "film"
        case .compress720, .compress480: return "film.stack"
        case .toGIF: return "sparkles.tv"
        }
    }

    enum Input { case images, pdf, text, media, video, audio }
    var input: Input {
        switch self {
        case .toJPG, .toPNG, .toHEIC, .compressImage, .resizeImage, .imagesToPDF: return .images
        case .pdfToImages: return .pdf
        case .textToPDF: return .text
        case .toM4A: return .media
        case .toWAV: return .audio
        case .toMP4, .compress720, .compress480, .toGIF: return .video
        }
    }

    /// Images → PDF always takes many files (one PDF); batch mode means "one output per input" for the others.
    var combinesInputs: Bool { self == .imagesToPDF }
}

enum ConvertError: LocalizedError {
    case unreadable, failed(String), noAudio, noVideo
    var errorDescription: String? {
        switch self {
        case .unreadable: return String(localized: "Could not open this file. Select it again.")
        case .failed(let m): return m
        case .noAudio: return String(localized: "This file has no audio track.")
        case .noVideo: return String(localized: "This file has no video track.")
        }
    }
}

enum Converters {
    static var outDir: URL {
        try? FileManager.default.createDirectory(at: AppFiles.converted, withIntermediateDirectories: true)
        return AppFiles.converted
    }

    static func output(_ input: URL, ext: String, suffix: String = "") -> URL {
        let stem = input.deletingPathExtension().lastPathComponent
        return AppFiles.uniqueURL(in: outDir, name: "\(stem)\(suffix).\(ext)")
    }

    // MARK: Images

    static func convertImage(_ url: URL, op: ConvertOp) throws -> URL {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              var image = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw ConvertError.unreadable
        }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        let orientation = props[kCGImagePropertyOrientation] as? UInt32 ?? 1
        var type = UTType.jpeg
        var quality: CGFloat = 0.92
        var suffix = ""
        switch op {
        case .toPNG: type = .png
        case .toHEIC: type = .heic; quality = 0.75
        case .compressImage: quality = 0.6; suffix = "_compressed"
        case .resizeImage:
            image = downscale(image, maxSide: 1080) ?? image
            suffix = "_1080"
        default: break
        }
        let out = output(url, ext: type.preferredFilenameExtension ?? "jpg", suffix: suffix)
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, type.identifier as CFString, 1, nil) else {
            throw ConvertError.failed(String(localized: "This image format can't be written on this iPhone."))
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality,
                                        kCGImagePropertyOrientation: orientation]
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ConvertError.failed(String(localized: "Could not save the image.")) }
        return out
    }

    static func downscale(_ image: CGImage, maxSide: CGFloat) -> CGImage? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let scale = min(1, maxSide / max(w, h))
        guard scale < 1 else { return image }
        let size = CGSize(width: (w * scale).rounded(), height: (h * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let img = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: size))
        }
        return img.cgImage
    }

    // MARK: PDF

    static func imagesToPDF(_ urls: [URL]) throws -> URL {
        let page = CGRect(x: 0, y: 0, width: 595.2, height: 841.8) // A4 @ 72 dpi
        let out = AppFiles.uniqueURL(in: outDir, name: "Images.pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        try renderer.writePDF(to: out) { ctx in
            for url in urls {
                guard let image = UIImage(contentsOfFile: url.path) else { continue }
                ctx.beginPage()
                let margin: CGFloat = 24
                let box = page.insetBy(dx: margin, dy: margin)
                let scale = min(box.width / image.size.width, box.height / image.size.height)
                let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                image.draw(in: CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height))
            }
        }
        return out
    }

    static func pdfToImages(_ url: URL) throws -> [URL] {
        guard let doc = PDFDocument(url: url) else { throw ConvertError.unreadable }
        let stem = url.deletingPathExtension().lastPathComponent
        let dir = AppFiles.uniqueURL(in: outDir, name: stem)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var out: [URL] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let scale: CGFloat = 2
            let img = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
            let file = dir.appendingPathComponent(String(format: "%@_page%03d.jpg", stem, i + 1))
            if let data = img.jpegData(compressionQuality: 0.9) {
                try data.write(to: file)
                out.append(file)
            }
        }
        return out
    }

    static func textToPDF(_ text: String, name: String = "Text") throws -> URL {
        let page = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)
        let formatter = UISimpleTextPrintFormatter(text: text)
        formatter.perPageContentInsets = UIEdgeInsets(top: 48, left: 48, bottom: 48, right: 48)
        formatter.font = .systemFont(ofSize: 12)
        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(formatter, startingAtPageAt: 0)
        renderer.setValue(page, forKey: "paperRect")
        renderer.setValue(page, forKey: "printableRect")
        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, page, nil)
        for i in 0..<renderer.numberOfPages {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: i, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()
        let out = AppFiles.uniqueURL(in: outDir, name: "\(name).pdf")
        try (data as Data).write(to: out)
        return out
    }

    // MARK: Audio / video

    struct MediaInfo {
        let size: Int64
        let resolution: CGSize?
        let duration: Double
        var text: String {
            var parts: [String] = []
            if let r = resolution { parts.append("\(Int(r.width))×\(Int(r.height))") }
            parts.append(FileUtils.formatSize(size))
            if duration > 0 { parts.append(String(format: "%.1f Mbps", Double(size) * 8 / duration / 1_000_000)) }
            return parts.joined(separator: " • ")
        }
    }

    static func info(_ url: URL) async -> MediaInfo {
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        var res: CGSize?
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let natural = try? await track.load(.naturalSize),
           let transform = try? await track.load(.preferredTransform) {
            let r = natural.applying(transform)
            res = CGSize(width: abs(r.width), height: abs(r.height))
        }
        return MediaInfo(size: FileUtils.fileSize(url), resolution: res, duration: duration.isFinite ? duration : 0)
    }

    /// Returns the output and a "before → after" report (Android shows the same after compressing).
    static func convertMedia(_ url: URL, op: ConvertOp, progress: @escaping @Sendable (Double) -> Void) async throws -> (URL, String?) {
        let asset = AVURLAsset(url: url)
        switch op {
        case .toWAV:
            return (try await toWAV(asset, input: url, progress: progress), nil)
        case .toGIF:
            return (try await toGIF(asset, input: url, progress: progress), nil)
        default:
            break
        }
        let hasVideo = !((try? await asset.loadTracks(withMediaType: .video)) ?? []).isEmpty
        let hasAudio = !((try? await asset.loadTracks(withMediaType: .audio)) ?? []).isEmpty
        var preset = AVAssetExportPresetHighestQuality
        var type: AVFileType = .mp4
        var ext = "mp4"
        var suffix = ""
        var note: String?
        let before = await info(url)
        switch op {
        case .toM4A:
            guard hasAudio else { throw ConvertError.noAudio }
            preset = AVAssetExportPresetAppleM4A; type = .m4a; ext = "m4a"
        case .toMP4:
            guard hasVideo else { throw ConvertError.noVideo }
        case .compress720, .compress480:
            guard hasVideo else { throw ConvertError.noVideo }
            let target: CGFloat = op == .compress720 ? 720 : 480
            preset = op == .compress720 ? AVAssetExportPreset1280x720 : AVAssetExportPreset640x480
            suffix = op == .compress720 ? "_720p" : "_480p"
            if let r = before.resolution, min(r.width, r.height) <= target {
                note = String(localized: "This video is already \(Int(min(r.width, r.height)))p or smaller, so it was only re-compressed.")
            }
        default:
            throw ConvertError.failed(String(localized: "Not a media conversion"))
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ConvertError.failed(String(localized: "This file can't be converted on this iPhone."))
        }
        let out = output(url, ext: ext, suffix: suffix)
        session.outputURL = out
        session.outputFileType = session.supportedFileTypes.contains(type) ? type : session.supportedFileTypes.first
        session.shouldOptimizeForNetworkUse = true
        let timer = Task {
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { c.resume() }
        }
        timer.cancel()
        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: out)
            throw ConvertError.failed(session.error?.localizedDescription ?? String(localized: "Conversion failed"))
        }
        progress(1)
        var report: String?
        if op == .compress720 || op == .compress480 {
            let after = await info(out)
            report = "\(before.text) → \(after.text)"
            if let note { report! += "\n" + note }
        }
        return (out, report)
    }

    private static func toWAV(_ asset: AVURLAsset, input: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw ConvertError.noAudio }
        let durationTime = try await asset.load(.duration)
        let duration = durationTime.seconds
        let out = output(input, ext: "wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let reader = try AVAssetReader(asset: asset)
        let readerOut = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(readerOut)
        let writer = try AVAssetWriter(outputURL: out, fileType: .wav)
        let writerIn = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        writerIn.expectsMediaDataInRealTime = false
        writer.add(writerIn)
        guard reader.startReading(), writer.startWriting() else {
            throw ConvertError.failed(reader.error?.localizedDescription ?? writer.error?.localizedDescription ?? "")
        }
        writer.startSession(atSourceTime: .zero)
        let queue = DispatchQueue(label: "shareyou.wav")
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            writerIn.requestMediaDataWhenReady(on: queue) {
                while writerIn.isReadyForMoreMediaData {
                    if let buffer = readerOut.copyNextSampleBuffer() {
                        writerIn.append(buffer)
                        let t = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
                        if duration > 0 { progress(min(1, t / duration)) }
                    } else {
                        writerIn.markAsFinished()
                        c.resume()
                        return
                    }
                }
            }
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw ConvertError.failed(writer.error?.localizedDescription ?? "") }
        return out
    }

    /// 10 fps, up to 8 s, 480 px wide, looping (same limits as Android's GIF encoder).
    private static func toGIF(_ asset: AVURLAsset, input: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { throw ConvertError.noVideo }
        let total = try await asset.load(.duration).seconds
        let duration = min(8, total.isFinite ? total : 0)
        let fps = 10.0
        let count = max(1, Int(duration * fps))
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 480, height: 480)
        gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 20)
        gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 20)
        let out = output(input, ext: "gif")
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw ConvertError.failed(String(localized: "Could not create the GIF."))
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
        for i in 0..<count {
            let time = CMTime(seconds: Double(i) / fps, preferredTimescale: 600)
            if let frame = try? await gen.image(at: time) {
                CGImageDestinationAddImage(dest, frame.image, frameProps)
            }
            progress(Double(i + 1) / Double(count))
        }
        guard CGImageDestinationFinalize(dest) else { throw ConvertError.failed(String(localized: "Could not create the GIF.")) }
        return out
    }
}
