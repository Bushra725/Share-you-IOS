import Foundation
import FirebaseAuth
import FirebaseFirestore

/// Cloud Firestore. Only signed-in users have a document: `users/{uid}`.
/// Fields: displayName, email, deviceName, avatar, platform, appVersion, fcmToken,
/// sentCount, sentBytes, receivedCount, receivedBytes, createdAt, updatedAt.
/// Security rules (Firebase/firestore.rules) only let a user read/write their own document.
@MainActor
final class FirestoreService {
    static let shared = FirestoreService()
    private lazy var db = Firestore.firestore()

    private var uid: String? { Auth.auth().currentUser?.uid }
    private func doc(_ uid: String) -> DocumentReference { db.collection("users").document(uid) }

    func upsertProfile() async {
        guard let user = Auth.auth().currentUser else { return }
        let ref = doc(user.uid)
        var data: [String: Any] = [
            "displayName": user.displayName ?? "",
            "email": user.email ?? "",
            "deviceName": Prefs.shared.deviceName,
            "avatar": Prefs.shared.avatar,
            "platform": "ios",
            "appVersion": AppConfig.version,
            "updatedAt": FieldValue.serverTimestamp()
        ]
        if let token = Prefs.shared.fcmToken { data["fcmToken"] = token }
        do {
            let snap = try await ref.getDocument()
            if !snap.exists {
                data["createdAt"] = FieldValue.serverTimestamp()
                data["sentCount"] = 0
                data["sentBytes"] = 0
                data["receivedCount"] = 0
                data["receivedBytes"] = 0
            }
            try await ref.setData(data, merge: true)
        } catch {
            Log.e("Firestore profile save failed", error)
        }
    }

    func saveFCMToken(_ token: String) async {
        guard let uid else { return }
        do {
            try await doc(uid).setData(["fcmToken": token, "updatedAt": FieldValue.serverTimestamp()], merge: true)
        } catch {
            Log.e("Firestore token save failed", error)
        }
    }

    func addTransferStats(sent: Bool, bytes: Int64) async {
        guard let uid else { return }
        let data: [String: Any] = [
            (sent ? "sentCount" : "receivedCount"): FieldValue.increment(Int64(1)),
            (sent ? "sentBytes" : "receivedBytes"): FieldValue.increment(bytes),
            "updatedAt": FieldValue.serverTimestamp()
        ]
        do {
            try await doc(uid).setData(data, merge: true)
        } catch {
            Log.e("Firestore stats failed", error)
        }
    }

    func deleteUserData(uid: String) async {
        do {
            try await doc(uid).delete()
        } catch {
            Log.e("Firestore delete failed", error)
        }
    }
}
