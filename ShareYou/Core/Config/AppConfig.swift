import Foundation

/// Read-only app configuration. Values come from the xcconfig files through Info.plist,
/// so nothing account-specific is hard-coded in Swift.
enum AppConfig {
    static func info(_ key: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static var appName: String {
        let name = info("CFBundleDisplayName")
        return name.isEmpty ? "Share you" : name
    }
    static var version: String { info("CFBundleShortVersionString") }
    static var build: String { info("CFBundleVersion") }

    static var privacyPolicyURL: URL {
        URL(string: info("SYPrivacyPolicyURL")) ?? URL(string: "https://sites.google.com/view/occessstudiollc/privacy-policy")!
    }

    static var termsURL: URL {
        URL(string: info("SYTermsURL")) ?? URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    }

    static var supportEmail: String? {
        let email = info("SYSupportEmail")
        return email.contains("@") ? email : nil
    }

    static var appStoreID: String? {
        let id = info("SYAppStoreID")
        guard !id.isEmpty, id.allSatisfy(\.isNumber), Int(id) ?? 0 > 0 else { return nil }
        return id
    }

    static var appStoreURL: URL? { appStoreID.flatMap { URL(string: "https://apps.apple.com/app/id\($0)") } }
    static var writeReviewURL: URL? { appStoreID.flatMap { URL(string: "https://apps.apple.com/app/id\($0)?action=write-review") } }
    static var moreAppsURL: URL? { URL(string: info("SYMoreAppsURL")) }

    // Transfer protocol constants — identical to the Android app, so the two can talk to each other.
    static let transferPort: UInt16 = 48520
    static let pcPort: UInt16 = 8888
    static let bonjourType = "_zapshare._tcp"
    static let qrPrefix = "ZAPSHARE:"

    /// Free users can send files up to 1 GB each (same as Android).
    static let freeFileLimit: Int64 = 1024 * 1024 * 1024
}
