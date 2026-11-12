import SwiftUI
import UIKit

/// App settings, persisted in UserDefaults. Mirrors Android's `Prefs`.
@MainActor
final class Prefs: ObservableObject {
    static let shared = Prefs()

    static let avatars = ["🐱", "🦊", "🐼", "🐸", "🐵", "🦄", "🐯", "🐨", "🐙", "🐧", "🦁", "🐶"]

    private let d = UserDefaults.standard

    private enum K {
        static let deviceName = "deviceName", avatar = "avatar", onboarded = "onboarded", theme = "themeMode"
        static let groupRelay = "groupRelay", keepScreenOn = "keepScreenOn", saveToPhotos = "saveToPhotos"
        static let premiumDebug = "premiumDebug", premiumAdUntil = "premiumAdUntil"
        static let batchDay = "batchConvertDay", playerDay = "playerExtraDay", vaultDay = "vaultExtraDay"
        static let cleanDay = "cleanSelectDay", groupDay = "groupExtraDay"
        static let sessions = "appSessions", firstTask = "firstTaskDone", attAsked = "attAsked"
        static let pushAsked = "pushAsked", fcmToken = "fcmToken", deleteAfterHide = "deleteAfterHide"
    }

    @Published var deviceName: String { didSet { d.set(deviceName, forKey: K.deviceName) } }
    @Published var avatar: Int { didSet { d.set(avatar, forKey: K.avatar) } }
    @Published var onboarded: Bool { didSet { d.set(onboarded, forKey: K.onboarded) } }
    /// 0 = follow system, 1 = light, 2 = dark
    @Published var themeMode: Int { didSet { d.set(themeMode, forKey: K.theme) } }
    @Published var groupRelay: Bool { didSet { d.set(groupRelay, forKey: K.groupRelay) } }
    @Published var keepScreenOn: Bool { didSet { d.set(keepScreenOn, forKey: K.keepScreenOn) } }
    @Published var saveToPhotos: Bool { didSet { d.set(saveToPhotos, forKey: K.saveToPhotos) } }
    @Published var deleteAfterHide: Bool { didSet { d.set(deleteAfterHide, forKey: K.deleteAfterHide) } }

    @Published var premiumDebug: Bool { didSet { d.set(premiumDebug, forKey: K.premiumDebug) } }
    @Published var premiumAdUntil: Date { didSet { d.set(premiumAdUntil.timeIntervalSince1970, forKey: K.premiumAdUntil) } }

    // One rewarded ad unlocks a feature until midnight (stored as yyyy-MM-dd).
    @Published var batchConvertDay: String { didSet { d.set(batchConvertDay, forKey: K.batchDay) } }
    @Published var playerExtraDay: String { didSet { d.set(playerExtraDay, forKey: K.playerDay) } }
    @Published var vaultExtraDay: String { didSet { d.set(vaultExtraDay, forKey: K.vaultDay) } }
    @Published var cleanSelectDay: String { didSet { d.set(cleanSelectDay, forKey: K.cleanDay) } }
    @Published var groupExtraDay: String { didSet { d.set(groupExtraDay, forKey: K.groupDay) } }

    var appSessions: Int {
        get { d.integer(forKey: K.sessions) }
        set { d.set(newValue, forKey: K.sessions) }
    }
    var firstTaskDone: Bool {
        get { d.bool(forKey: K.firstTask) }
        set { d.set(newValue, forKey: K.firstTask) }
    }
    var attAsked: Bool {
        get { d.bool(forKey: K.attAsked) }
        set { d.set(newValue, forKey: K.attAsked) }
    }
    var pushAsked: Bool {
        get { d.bool(forKey: K.pushAsked) }
        set { d.set(newValue, forKey: K.pushAsked) }
    }
    var fcmToken: String? {
        get { d.string(forKey: K.fcmToken) }
        set { d.set(newValue, forKey: K.fcmToken) }
    }

    private init() {
        d.register(defaults: [K.groupRelay: true, K.keepScreenOn: true, K.deleteAfterHide: false])
        deviceName = d.string(forKey: K.deviceName) ?? Prefs.defaultName()
        avatar = d.object(forKey: K.avatar) as? Int ?? Int.random(in: 0..<Prefs.avatars.count)
        onboarded = d.bool(forKey: K.onboarded)
        themeMode = d.integer(forKey: K.theme)
        groupRelay = d.bool(forKey: K.groupRelay)
        keepScreenOn = d.bool(forKey: K.keepScreenOn)
        saveToPhotos = d.bool(forKey: K.saveToPhotos)
        deleteAfterHide = d.bool(forKey: K.deleteAfterHide)
        premiumDebug = d.bool(forKey: K.premiumDebug)
        premiumAdUntil = Date(timeIntervalSince1970: d.double(forKey: K.premiumAdUntil))
        batchConvertDay = d.string(forKey: K.batchDay) ?? ""
        playerExtraDay = d.string(forKey: K.playerDay) ?? ""
        vaultExtraDay = d.string(forKey: K.vaultDay) ?? ""
        cleanSelectDay = d.string(forKey: K.cleanDay) ?? ""
        groupExtraDay = d.string(forKey: K.groupDay) ?? ""
    }

    var avatarEmoji: String { Prefs.avatars[max(0, min(avatar, Prefs.avatars.count - 1))] }

    var colorScheme: ColorScheme? {
        switch themeMode {
        case 1: return .light
        case 2: return .dark
        default: return nil
        }
    }

    /// iOS 16+ returns a generic name ("iPhone") for privacy, so add a short random tag to tell phones apart.
    private static func defaultName() -> String {
        let model = UIDevice.current.model
        let tag = String(Int.random(in: 100...999))
        return "\(model) \(tag)"
    }
}

/// Rewarded-ad unlocks. One rewarded ad unlocks the feature until midnight (local time).
/// Premium is always unlocked and never shows the video. Same rules as Android's `DayUnlock`.
@MainActor
enum DayUnlock {
    static let freeVault = 10
    static let freeGroupMembers = 3
    static let fullGroupMembers = 8

    static func today() -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private static var premium: Bool { StoreService.shared.isPremium }
    private static var p: Prefs { Prefs.shared }

    /// Converter: batch mode (convert many files at once).
    static func batch() -> Bool { premium || p.batchConvertDay == today() }
    static func grantBatch() { p.batchConvertDay = today() }

    /// Player: background playback and Picture in Picture.
    static func player() -> Bool { premium || p.playerExtraDay == today() }
    static func grantPlayer() { p.playerExtraDay = today() }

    /// Safebox: more than `freeVault` files.
    static func vault() -> Bool { premium || p.vaultExtraDay == today() }
    static func grantVault() { p.vaultExtraDay = today() }

    /// Clean: Select all / Smart select.
    static func cleanSelect() -> Bool { premium || p.cleanSelectDay == today() }
    static func grantCleanSelect() { p.cleanSelectDay = today() }

    /// Group share: up to 8 members instead of 3.
    static func groupLarge() -> Bool { premium || p.groupExtraDay == today() }
    static func grantGroup() { p.groupExtraDay = today() }
}
