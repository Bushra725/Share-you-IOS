import Foundation
import CryptoKit
import CommonCrypto
import LocalAuthentication
import Security

struct VaultEntry: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let mime: String
    let size: Int64
    let added: Date
    var category: FileCategory { FileUtils.categoryOf(mime: mime, name: name) }
}

/// Encrypted Safebox (port of Android's `Vault.kt`).
///  - Each file is encrypted with AES-256-GCM in 1 MB chunks (multi-GB videos work without loading into memory).
///  - The data key lives in the iOS Keychain (this device only, never synced or backed up).
///  - Access is gated by a PIN (PBKDF2-SHA256 hashed), an optional pattern, and optionally Face ID / Touch ID.
///  - File names are hidden: files are stored as random ids and the index itself is encrypted.
@MainActor
final class Vault: ObservableObject {
    static let shared = Vault()

    private static let pbkdf2Rounds: UInt32 = 120_000

    static let questions: [String] = [
        String(localized: "What city were you born in?"),
        String(localized: "What is your mother's first name?"),
        String(localized: "What was the name of your first school?"),
        String(localized: "What is your favorite color?"),
        String(localized: "What is your first pet's name?")
    ]

    @Published private(set) var isSetUp: Bool
    @Published private(set) var isUnlocked = false
    @Published private(set) var entries: [VaultEntry] = []
    @Published var biometricEnabled: Bool { didSet { UserDefaults.standard.set(biometricEnabled, forKey: "vaultBiometric") } }
    @Published private(set) var hasPattern: Bool
    @Published private(set) var hasQuestions: Bool

    /// Skip auto-lock while a decrypted preview (or similar) is on screen.
    var suppressAutoLock = false

    private var key: SymmetricKey?

    private init() {
        isSetUp = Keychain.read("vault.pin") != nil && Keychain.read("vault.dek") != nil
        hasPattern = Keychain.read("vault.pattern") != nil
        hasQuestions = Keychain.read("vault.questions") != nil
        biometricEnabled = UserDefaults.standard.bool(forKey: "vaultBiometric")
    }

    // MARK: - Folders

    private var dir: URL {
        var url = AppFiles.appSupport.appendingPathComponent("Vault", isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true // the key is device-only, so a backup could never be opened
            try? url.setResourceValues(values)
        }
        return url
    }
    private var indexURL: URL { dir.appendingPathComponent("index.bin") }
    private var tempDir: URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vault_tmp", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Setup & unlock

    func setup(pin: String) throws {
        let dek = SymmetricKey(size: .bits256)
        try Keychain.save("vault.dek", dek.withUnsafeBytes { Data($0) })
        try savePin(pin)
        key = dek
        entries = []
        try saveIndex()
        isSetUp = true
        isUnlocked = true
    }

    func unlock(pin: String) -> Bool {
        guard verify(pin, stored: "vault.pin") else { return false }
        open()
        return isUnlocked
    }

    func unlockWithPattern(_ pattern: String) -> Bool {
        guard verify(pattern, stored: "vault.pattern") else { return false }
        open()
        return isUnlocked
    }

    func unlockWithBiometrics() async -> Bool {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err) else { return false }
        do {
            let ok = try await ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                                  localizedReason: String(localized: "Unlock your Safebox"))
            if ok { open() }
            return ok && isUnlocked
        } catch {
            return false
        }
    }

    static var biometryName: String? {
        let ctx = LAContext()
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return nil }
        switch ctx.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        default: return nil
        }
    }

    private func open() {
        guard let raw = Keychain.read("vault.dek") else { return }
        key = SymmetricKey(data: raw)
        loadIndex()
        isUnlocked = true
    }

    func lock() {
        guard !suppressAutoLock else { return }
        key = nil
        entries = []
        isUnlocked = false
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Always locks, even during preview — used by the explicit "Lock now" action.
    func lockNow() {
        suppressAutoLock = false
        key = nil
        entries = []
        isUnlocked = false
        try? FileManager.default.removeItem(at: tempDir)
    }

    func changePin(old: String, new: String) -> Bool {
        guard verify(old, stored: "vault.pin") else { return false }
        return (try? savePin(new)) != nil
    }

    func setPattern(_ pattern: String) {
        if let data = Self.hashRecord(pattern) { try? Keychain.save("vault.pattern", data) }
        hasPattern = true
    }

    func clearPattern() {
        Keychain.delete("vault.pattern")
        hasPattern = false
    }

    // MARK: - Recovery questions (optional)

    func saveQuestions(_ answers: [(Int, String)]) {
        let records: [[String: String]] = answers.compactMap { q, a in
            guard let rec = Self.hashRecord(Self.normalize(a)),
                  let obj = try? JSONSerialization.jsonObject(with: rec) as? [String: String] else { return nil }
            return ["q": String(q), "salt": obj["salt"] ?? "", "hash": obj["hash"] ?? ""]
        }
        if let data = try? JSONSerialization.data(withJSONObject: records) {
            try? Keychain.save("vault.questions", data)
            hasQuestions = true
        }
    }

    func questionIndexes() -> [Int] {
        guard let data = Keychain.read("vault.questions"),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else { return [] }
        return list.compactMap { Int($0["q"] ?? "") }
    }

    /// True when every answer matches. Then the PIN can be reset.
    func checkQuestions(_ answers: [(Int, String)]) -> Bool {
        guard let data = Keychain.read("vault.questions"),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: String]], !list.isEmpty else { return false }
        for rec in list {
            guard let q = Int(rec["q"] ?? ""), let answer = answers.first(where: { $0.0 == q })?.1,
                  let salt = Data(base64Encoded: rec["salt"] ?? ""), let hash = Data(base64Encoded: rec["hash"] ?? ""),
                  Self.pbkdf2(Self.normalize(answer), salt: salt) == hash else { return false }
        }
        return true
    }

    func resetPin(_ pin: String) {
        try? savePin(pin)
        open()
    }

    private static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: - Files

    var count: Int { entries.count }

    func add(_ url: URL, name: String? = nil) async throws {
        guard let key else { throw ConvertError.failed(String(localized: "Safebox is locked")) }
        let id = UUID().uuidString
        let dest = dir.appendingPathComponent("\(id).zv")
        let fileName = FileUtils.safeName(name ?? url.lastPathComponent)
        let size = try await Task.detached(priority: .userInitiated) {
            try Self.encrypt(from: url, to: dest, key: key)
        }.value
        entries.insert(VaultEntry(id: id, name: fileName, mime: FileUtils.mimeOf(fileName), size: size, added: Date()), at: 0)
        try saveIndex()
        AnalyticsService.log(.vaultAdded)
    }

    /// Decrypts to a temporary file for viewing. Temp files are wiped when the Safebox locks.
    func openTemp(_ entry: VaultEntry) async throws -> URL {
        guard let key else { throw ConvertError.failed(String(localized: "Safebox is locked")) }
        let src = dir.appendingPathComponent("\(entry.id).zv")
        let folder = tempDir.appendingPathComponent(entry.id, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let out = folder.appendingPathComponent(entry.name)
        if FileManager.default.fileExists(atPath: out.path) { return out }
        try await Task.detached(priority: .userInitiated) { try Self.decrypt(from: src, to: out, key: key) }.value
        return out
    }

    /// Moves a file out of the Safebox into Files › Restored.
    func restore(_ entry: VaultEntry) async throws -> URL {
        let temp = try await openTemp(entry)
        let dest = AppFiles.uniqueURL(in: AppFiles.restored, name: entry.name)
        try FileManager.default.moveItem(at: temp, to: dest)
        delete(entry)
        return dest
    }

    func delete(_ entry: VaultEntry) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(entry.id).zv"))
        entries.removeAll { $0.id == entry.id }
        try? saveIndex()
    }

    // MARK: - Index (encrypted JSON)

    private func saveIndex() throws {
        guard let key else { return }
        let data = try JSONEncoder().encode(entries)
        let sealed = try AES.GCM.seal(data, using: key)
        guard let combined = sealed.combined else { return }
        try combined.write(to: indexURL, options: [.atomic, .completeFileProtection])
    }

    private func loadIndex() {
        guard let key, let data = try? Data(contentsOf: indexURL),
              let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: key) else { entries = []; return }
        entries = (try? JSONDecoder().decode([VaultEntry].self, from: plain)) ?? []
    }

    // MARK: - Crypto

    /// File format: "ZVLT" then repeated [UInt32 big-endian length][nonce | ciphertext | tag] per 1 MB chunk.
    nonisolated private static func encrypt(from src: URL, to dest: URL, key: SymmetricKey) throws -> Int64 {
        let scoped = src.startAccessingSecurityScopedResource()
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }
        let input = try FileHandle(forReadingFrom: src)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: dest.path, contents: nil, attributes: [.protectionKey: FileProtectionType.complete])
        let output = try FileHandle(forWritingTo: dest)
        defer { try? output.close() }
        try output.write(contentsOf: VaultFormat.magic)
        var total: Int64 = 0
        while let piece = try input.read(upToCount: VaultFormat.chunk), !piece.isEmpty {
            let sealed = try AES.GCM.seal(piece, using: key)
            guard let combined = sealed.combined else { throw ConvertError.failed("seal") }
            var len = UInt32(combined.count).bigEndian
            try output.write(contentsOf: Data(bytes: &len, count: 4))
            try output.write(contentsOf: combined)
            total += Int64(piece.count)
        }
        return total
    }

    nonisolated private static func decrypt(from src: URL, to dest: URL, key: SymmetricKey) throws {
        let input = try FileHandle(forReadingFrom: src)
        defer { try? input.close() }
        guard try input.read(upToCount: 4) == VaultFormat.magic else { throw ConvertError.unreadable }
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let output = try FileHandle(forWritingTo: dest)
        defer { try? output.close() }
        while let lenData = try input.read(upToCount: 4), lenData.count == 4 {
            let b = [UInt8](lenData)
            let len = Int(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
            guard len > 0, len <= VaultFormat.chunk + 64, let combined = try input.read(upToCount: len), combined.count == len else {
                throw ConvertError.unreadable
            }
            let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: key)
            try output.write(contentsOf: plain)
        }
    }

    // MARK: - PIN hashing (PBKDF2-SHA256)

    private func savePin(_ pin: String) throws {
        guard let rec = Self.hashRecord(pin) else { throw ConvertError.failed("hash") }
        try Keychain.save("vault.pin", rec)
    }

    private func verify(_ secret: String, stored: String) -> Bool {
        guard let data = Keychain.read(stored),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let salt = Data(base64Encoded: obj["salt"] ?? ""), let hash = Data(base64Encoded: obj["hash"] ?? "") else { return false }
        return Self.pbkdf2(secret, salt: salt) == hash
    }

    private static func hashRecord(_ secret: String) -> Data? {
        var salt = Data(count: 16)
        let ok = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard ok == errSecSuccess else { return nil }
        let hash = pbkdf2(secret, salt: salt)
        return try? JSONSerialization.data(withJSONObject: ["salt": salt.base64EncodedString(), "hash": hash.base64EncodedString()])
    }

    private static func pbkdf2(_ secret: String, salt: Data) -> Data {
        let password = Array(secret.utf8).map { Int8(bitPattern: $0) }
        var out = Data(count: 32)
        let count = out.count
        _ = out.withUnsafeMutableBytes { outPtr in
            salt.withUnsafeBytes { saltPtr in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, password.count,
                                     saltPtr.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), pbkdf2Rounds,
                                     outPtr.bindMemory(to: UInt8.self).baseAddress, count)
            }
        }
        return out
    }
}

/// On-disk format constants (outside the main-actor class so the crypto can run on background threads).
private enum VaultFormat {
    static let chunk = 1 << 20
    static let magic = Data("ZVLT".utf8)
}

/// Minimal Keychain wrapper (generic passwords, this device only).
enum Keychain {
    private static let service = (Bundle.main.bundleIdentifier ?? "ShareYou") + ".vault"

    static func save(_ account: String, _ data: Data) throws {
        delete(account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: data
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    static func read(_ account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
