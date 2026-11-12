import Foundation
import Network

/// One live TCP connection to another Share you device (Android or iOS). Bi-directional:
/// both sides can send files at any time. Writes are serialized through a queue; reads run in their own loop.
/// Port of Android's `Peer.kt` — same frames, same JSON keys.
final class PeerConnection: @unchecked Sendable {
    let id = UUID().uuidString
    private(set) var name = "Device"
    private(set) var avatar = 0
    private(set) var helloReceived = false

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let meter: ProgressMeter
    private let myName: String
    private let myAvatar: Int
    private weak var manager: TransferManager?

    private let lock = NSLock()
    private var _closed = false
    private var closed: Bool { lock.lock(); defer { lock.unlock() }; return _closed }

    private enum Job {
        case hello
        case peers([PeerInfo])
        case file(TransferItem, URL)
    }
    private let jobs: AsyncStream<Job>
    private let jobSink: AsyncStream<Job>.Continuation

    /// `connection` must already be in the `.ready` state.
    init(connection: NWConnection, queue: DispatchQueue, manager: TransferManager, meter: ProgressMeter, myName: String, myAvatar: Int) {
        self.connection = connection
        self.queue = queue
        self.manager = manager
        self.meter = meter
        self.myName = myName
        self.myAvatar = myAvatar
        var sink: AsyncStream<Job>.Continuation!
        self.jobs = AsyncStream(bufferingPolicy: .unbounded) { sink = $0 }
        self.jobSink = sink
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        Task.detached { [self] in await writerLoop() }
        Task.detached { [self] in await readerLoop() }
        jobSink.yield(.hello)
    }

    func enqueueFile(_ item: TransferItem, url: URL) { jobSink.yield(.file(item, url)) }
    func enqueuePeers(_ list: [PeerInfo]) { jobSink.yield(.peers(list)) }
    func info() -> PeerInfo { PeerInfo(id: id, name: name, avatar: avatar) }

    // MARK: - Writing

    private func writerLoop() async {
        for await job in jobs {
            if closed {
                if case .file(let item, _) = job { await manager?.markFailed(item.id, String(localized: "Disconnected")) }
                continue
            }
            do {
                switch job {
                case .hello:
                    try await send(Wire.frame(Wire.hello, ["name": myName, "avatar": myAvatar, "v": 1]))
                case .peers(let list):
                    let arr = list.map { ["id": $0.id, "name": $0.name, "avatar": $0.avatar] as [String: Any] }
                    try await send(Wire.frame(Wire.peers, ["peers": arr]))
                case .file(let item, let url):
                    try await sendFile(item, url: url)
                }
            } catch {
                close()
            }
        }
    }

    private func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            })
        }
    }

    private func sendFile(_ item: TransferItem, url: URL) async throws {
        await manager?.markActive(item.id)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            // Nothing written yet, the stream is still in sync.
            await manager?.markFailed(item.id, TransferError.cannotOpen.localizedDescription)
            return
        }
        defer { try? handle.close() }
        do {
            try await send(Wire.frame(Wire.file, [
                "name": item.name,
                "size": item.size,
                "mime": item.mime,
                "fid": item.shareKey.isEmpty ? item.id : item.shareKey,
                "origin": item.originName.isEmpty ? myName : item.originName,
                "relay": item.relay
            ]))
            var remaining = item.size
            while remaining > 0 {
                let n = Int(min(Int64(Wire.bufferSize), remaining))
                guard let chunk = try handle.read(upToCount: n), !chunk.isEmpty else { throw TransferError.fileChanged }
                try await send(chunk)
                remaining -= Int64(chunk.count)
                meter.add(item.id, chunk.count)
            }
            await manager?.markSent(item)
        } catch {
            await manager?.markFailed(item.id, error.localizedDescription)
            // The stream is out of sync after a partial file: drop the connection.
            close()
            throw error
        }
    }

    // MARK: - Reading

    private func receiveChunk(max: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: max) { data, _, isComplete, error in
                if let error { c.resume(throwing: error); return }
                if let data, !data.isEmpty { c.resume(returning: data); return }
                if isComplete { c.resume(throwing: TransferError.closed); return }
                c.resume(returning: Data())
            }
        }
    }

    private func readExactly(_ n: Int) async throws -> Data {
        var out = Data()
        out.reserveCapacity(n)
        while out.count < n {
            if closed { throw TransferError.closed }
            out.append(try await receiveChunk(max: n - out.count))
        }
        return out
    }

    private func readerLoop() async {
        do {
            while !closed {
                let head = [UInt8](try await readExactly(5))
                let type = head[0]
                let len = Int(UInt32(head[1]) << 24 | UInt32(head[2]) << 16 | UInt32(head[3]) << 8 | UInt32(head[4]))
                guard len >= 0, len <= Wire.maxHeader else { throw TransferError.badFrame }
                let body = try await readExactly(len)
                let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
                switch type {
                case Wire.hello:
                    name = (json["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Device"
                    avatar = (json["avatar"] as? NSNumber)?.intValue ?? 0
                    helloReceived = true
                    await manager?.onPeerHello(self)
                case Wire.file:
                    try await receiveFile(json)
                case Wire.peers:
                    let arr = json["peers"] as? [[String: Any]] ?? []
                    let list = arr.compactMap { o -> PeerInfo? in
                        guard let id = o["id"] as? String else { return nil }
                        return PeerInfo(id: id, name: o["name"] as? String ?? "", avatar: (o["avatar"] as? NSNumber)?.intValue ?? 0)
                    }
                    await manager?.onPeerList(list)
                case Wire.bye:
                    close()
                    return
                default:
                    break
                }
            }
        } catch {
            // fall through to close
        }
        close()
    }

    private func receiveFile(_ json: [String: Any]) async throws {
        let size = (json["size"] as? NSNumber)?.int64Value ?? 0
        let fileName = FileUtils.safeName(json["name"] as? String ?? "file")
        let rawMime = json["mime"] as? String ?? ""
        let mime = FileUtils.normalizeMime(fileName, rawMime.isEmpty ? FileUtils.mimeOf(fileName) : rawMime)
        let origin = (json["origin"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name
        let shareKey = (json["fid"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "\(fileName)|\(size)"
        let relay = (json["relay"] as? NSNumber)?.boolValue ?? false

        guard let manager else { try await discard(size); return }
        if !(await manager.claimGroupFile(shareKey, peerId: id)) {
            try await discard(size)
            return
        }
        let (item, finalURL) = await manager.startIncoming(peer: self, name: fileName, size: size, mime: mime,
                                                             origin: origin, shareKey: shareKey, relay: relay)
        let partURL = URL(fileURLWithPath: finalURL.path + ".part")
        FileManager.default.createFile(atPath: partURL.path, contents: nil)
        let handle = try? FileHandle(forWritingTo: partURL)
        var ok = false
        var failure: Error?
        do {
            var remaining = size
            while remaining > 0 {
                let chunk = try await receiveChunk(max: Int(min(Int64(Wire.bufferSize), remaining)))
                if chunk.isEmpty { continue }
                try handle?.write(contentsOf: chunk)
                remaining -= Int64(chunk.count)
                meter.add(item.id, chunk.count)
            }
            ok = handle != nil
        } catch {
            failure = error
        }
        try? handle?.close()
        if ok, (try? FileManager.default.moveItem(at: partURL, to: finalURL)) != nil {
            await manager.markReceived(from: self, item: item, url: finalURL)
        } else {
            try? FileManager.default.removeItem(at: partURL)
            await manager.markFailed(item.id, handle == nil ? String(localized: "No storage access") : String(localized: "Interrupted"))
        }
        if let failure { throw failure }
    }

    private func discard(_ size: Int64) async throws {
        var remaining = size
        while remaining > 0 {
            let chunk = try await receiveChunk(max: Int(min(Int64(Wire.bufferSize), remaining)))
            remaining -= Int64(chunk.count)
        }
    }

    // MARK: - Closing

    func close() {
        lock.lock()
        if _closed { lock.unlock(); return }
        _closed = true
        lock.unlock()
        jobSink.finish()
        connection.cancel()
        let owner = manager
        Task { @MainActor in owner?.onPeerClosed(self) }
    }

    /// Polite goodbye, then close.
    func sayBye() {
        guard !closed, let frame = try? Wire.frame(Wire.bye, [:]) else { close(); return }
        connection.send(content: frame, completion: .contentProcessed { [weak self] _ in self?.close() })
    }
}
