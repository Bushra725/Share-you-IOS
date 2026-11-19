import Foundation
import Network

/// "Connect to PC": a tiny HTTP/1.1 server on the iPhone (port 8888). The PC opens
/// http://<iphone-ip>:8888/?k=<code> in any browser — no app needed on the PC.
/// Same routes and same web page as the Android `PcServer` (NanoHTTPD):
///   GET  /            the page (with the access code injected)
///   GET  /api/info    { name, model }
///   GET  /api/files   { shared: [...], received: [...] }
///   GET  /dl?id=s0    download a shared (s) or received (r) file
///   POST /upload      multipart/form-data, field "file"
final class PcServer: @unchecked Sendable {
    struct FileEntry: Sendable { let url: URL; let name: String; let size: Int64; let mime: String }

    /// Called on the server queue to read the current lists.
    var snapshot: @Sendable () -> (shared: [FileEntry], received: [FileEntry], name: String) = { ([], [], "iPhone") }
    var onReceived: @Sendable (URL, String, Int64) -> Void = { _, _, _ in }
    /// name, bytes written, expected size. Fired while a PC upload is still streaming.
    var onReceiveProgress: @Sendable (String, Int64, Int64) -> Void = { _, _, _ in }
    var onLog: @Sendable (String) -> Void = { _ in }

    private let token: String
    private let page: String
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "shareyou.pc", attributes: .concurrent)

    init(token: String) {
        self.token = token
        let url = Bundle.main.url(forResource: "pc_index", withExtension: "html")
        let html = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "<h1>Share you</h1>"
        self.page = html.replacingOccurrences(of: "data-key=\"\"", with: "data-key=\"\(token)\"")
    }

    func start() async throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let port = NWEndpoint.Port(rawValue: AppConfig.pcPort) else { return }
        let l = try NWListener(using: params, on: port)
        l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        listener = l
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let once = OnceFlag()
            l.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.claim() { c.resume() }
                case .failed(let e): if once.claim() { c.resume(throwing: e) }
                case .cancelled: if once.claim() { c.resume(throwing: TransferError.closed) }
                default: break
                }
            }
            l.start(queue: queue)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling

    private func handle(_ conn: NWConnection) {
        conn.start(queue: DispatchQueue(label: "shareyou.pc.conn"))
        Task.detached { [self] in
            do {
                try await serve(HTTPConnection(conn))
            } catch {
                conn.cancel()
            }
        }
    }

    private func serve(_ http: HTTPConnection) async throws {
        let req = try await http.readRequest()
        if req.path == "/" || req.path == "/index.html" {
            try await http.respond(200, "text/html; charset=utf-8", Data(page.utf8))
            return
        }
        let key = req.query["k"] ?? req.headers["x-zap-key"]
        guard key == token else {
            try await http.respond(403, "text/plain", Data("Wrong access code".utf8))
            return
        }
        switch (req.method, req.path) {
        case ("GET", "/api/info"):
            let s = snapshot()
            try await http.respondJSON(["name": s.name, "model": "iPhone"])
        case ("GET", "/api/files"):
            let s = snapshot()
            func arr(_ prefix: String, _ list: [FileEntry]) -> [[String: Any]] {
                list.enumerated().map { i, f in ["id": "\(prefix)\(i)", "name": f.name, "size": f.size, "mime": f.mime] }
            }
            try await http.respondJSON(["shared": arr("s", s.shared), "received": arr("r", s.received)])
        case ("GET", "/dl"):
            let s = snapshot()
            let id = req.query["id"] ?? ""
            let index = Int(id.dropFirst()) ?? -1
            let list = id.hasPrefix("s") ? s.shared : id.hasPrefix("r") ? s.received : []
            guard list.indices.contains(index) else {
                try await http.respond(404, "text/plain", Data("Not found".utf8))
                return
            }
            let f = list[index]
            try await http.sendFile(f.url, name: f.name, mime: f.mime)
            onLog(String(localized: "PC downloaded \(f.name)"))
        case ("POST", "/upload"):
            do {
                let (url, name, size) = try await http.receiveUpload(into: AppFiles.fromPC) { name, written, total in
                    self.onReceiveProgress(name, written, total)
                }
                onReceived(url, name, size)
                onLog(String(localized: "Received \(name) from PC"))
                try await http.respondJSON(["ok": true])
            } catch {
                onLog(String(localized: "Upload failed: \(error.localizedDescription)"))
                try await http.respond(500, "text/plain", Data(error.localizedDescription.utf8))
            }
        default:
            try await http.respond(404, "text/plain", Data("Not found".utf8))
        }
    }
}

/// Minimal HTTP/1.1 over one NWConnection. Every response closes the connection (like the Android server).
final class HTTPConnection: @unchecked Sendable {
    struct Request {
        var method = "GET"
        var path = "/"
        var query: [String: String] = [:]
        var headers: [String: String] = [:]
    }

    private let conn: NWConnection
    /// Bytes received after the header block (start of the body).
    private var buffer = Data()

    init(_ conn: NWConnection) { self.conn = conn }

    private func receive(max: Int = 256 * 1024) async throws -> Data {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: max) { data, _, complete, error in
                if let error { c.resume(throwing: error); return }
                if let data, !data.isEmpty { c.resume(returning: data); return }
                if complete { c.resume(throwing: TransferError.closed); return }
                c.resume(returning: Data())
            }
        }
    }

    private func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            })
        }
    }

    func readRequest() async throws -> Request {
        let separator = Data("\r\n\r\n".utf8)
        while buffer.range(of: separator) == nil {
            guard buffer.count < 64 * 1024 else { throw TransferError.badFrame }
            buffer.append(try await receive(max: 16 * 1024))
        }
        let range = buffer.range(of: separator)!
        let head = String(decoding: buffer[buffer.startIndex..<range.lowerBound], as: UTF8.self)
        buffer = Data(buffer[range.upperBound...])
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        var req = Request()
        if first.count >= 2 {
            req.method = String(first[0]).uppercased()
            let target = String(first[1])
            let comps = URLComponents(string: target)
            req.path = comps?.path ?? target
            for item in comps?.queryItems ?? [] { req.query[item.name] = item.value ?? "" }
        }
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let k = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            req.headers[k] = v
        }
        currentHeaders = req.headers
        return req
    }

    private var currentHeaders: [String: String] = [:]

    private static func statusText(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        default: return "Internal Server Error"
        }
    }

    private func header(_ code: Int, _ type: String, length: Int64, extra: [String: String] = [:]) -> Data {
        var h = "HTTP/1.1 \(code) \(Self.statusText(code))\r\nContent-Type: \(type)\r\nContent-Length: \(length)\r\n"
        h += "Connection: close\r\nCache-Control: no-store\r\n"
        for (k, v) in extra { h += "\(k): \(v)\r\n" }
        h += "\r\n"
        return Data(h.utf8)
    }

    func respond(_ code: Int, _ type: String, _ body: Data) async throws {
        try await send(header(code, type, length: Int64(body.count)) + body)
        finish()
    }

    func respondJSON(_ object: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try await respond(200, "application/json", data)
    }

    func sendFile(_ url: URL, name: String, mime: String) async throws {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            try await respond(404, "text/plain", Data("Not found".utf8))
            return
        }
        defer { try? handle.close() }
        let size = FileUtils.fileSize(url)
        let clean = name.replacingOccurrences(of: "\"", with: "")
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/;,"))) ?? clean
        try await send(header(200, mime, length: size, extra: [
            "Content-Disposition": "attachment; filename=\"\(clean)\"; filename*=UTF-8''\(encoded)"
        ]))
        while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
            try await send(chunk)
        }
        finish()
    }

    /// Streams a multipart upload straight to disk (works for multi-GB files).
    /// `onProgress` reports bytes written against the expected file size while the body is still arriving.
    func receiveUpload(into dir: URL, onProgress: (@Sendable (String, Int64, Int64) -> Void)? = nil) async throws -> (URL, String, Int64) {
        let contentType = currentHeaders["content-type"] ?? ""
        guard let bRange = contentType.range(of: "boundary=") else { throw UploadError.noFile }
        var boundary = String(contentType[bRange.upperBound...])
        if let semi = boundary.firstIndex(of: ";") { boundary = String(boundary[..<semi]) }
        boundary = boundary.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        let total = Int64(currentHeaders["content-length"] ?? "") ?? -1
        var consumed = Int64(buffer.count)

        func more() async throws {
            if total >= 0 && consumed >= total { throw UploadError.truncated }
            let d = try await receive()
            consumed += Int64(d.count)
            buffer.append(d)
        }

        // 1) Part headers.
        let headerEnd = Data("\r\n\r\n".utf8)
        while buffer.range(of: headerEnd) == nil {
            guard buffer.count < 64 * 1024 else { throw UploadError.noFile }
            try await more()
        }
        let hr = buffer.range(of: headerEnd)!
        let partHead = String(decoding: buffer[buffer.startIndex..<hr.lowerBound], as: UTF8.self)
        buffer = Data(buffer[hr.upperBound...])
        var filename = "upload.bin"
        if let r = partHead.range(of: "filename=\"") {
            let rest = partHead[r.upperBound...]
            if let end = rest.firstIndex(of: "\"") { filename = String(rest[..<end]) }
        }
        let name = FileUtils.safeName((filename as NSString).lastPathComponent)
        // Content-Length covers the whole multipart body. What is left after the part headers is the file plus a short closing boundary.
        let expected = total > 0 ? max(Int64(1), total - consumed) : Int64(0)

        // 2) File body until "\r\n--boundary".
        let category = FileUtils.categoryOf(mime: FileUtils.mimeOf(name), name: name)
        let target = AppFiles.uniqueURL(in: dir.appendingPathComponent(category.folder, isDirectory: true), name: name)
        let part = URL(fileURLWithPath: target.path + ".part")
        FileManager.default.createFile(atPath: part.path, contents: nil)
        guard let out = try? FileHandle(forWritingTo: part) else { throw UploadError.storage }
        var written: Int64 = 0
        let delimiter = Data("\r\n--\(boundary)".utf8)
        do {
            while true {
                if let r = buffer.range(of: delimiter) {
                    let chunk = buffer[buffer.startIndex..<r.lowerBound]
                    try out.write(contentsOf: chunk)
                    written += Int64(chunk.count)
                    onProgress?(name, written, expected > 0 ? expected : written)
                    break
                }
                // Keep a tail long enough to hold a delimiter split across reads.
                let keep = delimiter.count
                if buffer.count > keep {
                    let cut = buffer.count - keep
                    let chunk = buffer.prefix(cut)
                    try out.write(contentsOf: chunk)
                    written += Int64(chunk.count)
                    onProgress?(name, written, expected > 0 ? expected : written)
                    buffer = Data(buffer.suffix(keep))
                }
                try await more()
            }
            try out.close()
        } catch {
            try? out.close()
            try? FileManager.default.removeItem(at: part)
            throw error
        }
        // 3) Drain the closing boundary so the browser sees a clean response.
        while total >= 0 && consumed < total {
            let d = try await receive()
            consumed += Int64(d.count)
        }
        try FileManager.default.moveItem(at: part, to: target)
        return (target, name, written)
    }

    private func finish() {
        conn.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [conn] _ in
            conn.cancel()
        })
    }

    enum UploadError: LocalizedError {
        case noFile, truncated, storage
        var errorDescription: String? {
            switch self {
            case .noFile: return String(localized: "No file")
            case .truncated: return String(localized: "The upload stopped before the end")
            case .storage: return String(localized: "Could not save the file on the phone")
            }
        }
    }
}
