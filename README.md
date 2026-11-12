# Share you — iOS

The iOS version of **Share you** (Android 1.6.13). It is native **Swift + SwiftUI**, targets **iOS 16+**, and runs on iPhone and iPad. Every dependency comes through **Swift Package Manager**.

| | |
|---|---|
| Bundle ID | `com.ol.your.mob.send.share.files` |
| Version | 1.0.0 (build 1) |
| Firebase project | `yourmob-send-share-files` |
| Privacy policy | https://sites.google.com/view/occessstudiollc/privacy-policy |

**Why native and not Flutter or React Native:** almost every feature here depends on an Apple framework:

- **Transfers:** Network.framework, Bonjour and NEHotspotConfiguration
- **Clean:** PhotoKit
- **Safebox:** CryptoKit, the Keychain and Face ID
- **Player and converter:** AVFoundation and PDFKit
- **Premium:** StoreKit 2

On top of that, the Crashlytics run script, App Attest and APNs are all set up in Xcode. With a cross-platform framework, each of these would need its own bridge to native code.

---

## 1. Open and run

1. Install the latest **Xcode** (version 16 or newer) on a Mac.
2. Copy `Config/Secrets.example.xcconfig` to `Config/Secrets.xcconfig` and set `DEVELOPMENT_TEAM` to your Team ID. Set your support email and App Store ID there too.
3. Double-click `ShareYou.xcodeproj`. Xcode downloads the packages automatically (Firebase, Google Sign-In, Google Mobile Ads, UMP), which takes a few minutes the first time.
4. Pick your iPhone and press **Run ▶**. Use two real devices to test transfers, because the Simulator can't join hotspots or use the camera.

> **Build note:** this project was written on Linux without Xcode, so it has **not been compiled yet**. The code was checked by reading it and with automated consistency checks. Expect a few small compiler fixes on the first build in Xcode. They will most likely be API renames in the Google Mobile Ads 12 and UMP 3 SDKs, or warnings about Swift concurrency.

The `ShareYou/` folder is a **synchronized folder** (Xcode 16 feature). Any file you add there is picked up automatically. `tools/generate_xcodeproj.py` regenerates the project file if you ever need to reset it.

---

## 2. Feature parity with Android

The iPhone app uses the **same wire protocol** as the Android app:

- TCP port `48520`
- frames laid out as `[type][len][JSON]` plus the file bytes
- the same QR code format (`ZAPSHARE:{…}`)
- the same Bonjour service (`_zapshare._tcp`)
- the PC page on port `8888`

So **an iPhone and an Android phone can send files to each other in both directions.**

| Android feature | iOS version | Notes |
|---|---|---|
| Send / Receive with a QR code | ✅ | When the iPhone scans an Android QR code, it **joins the phone's offline hotspot automatically** (NEHotspotConfiguration). |
| Same Wi-Fi with nearby discovery | ✅ | Bonjour. iPhone to iPhone also works **with no Wi-Fi**, over Apple's peer-to-peer Wi-Fi. |
| Manual IP | ✅ | |
| Two-way transfer, "Send more" | ✅ | |
| Group share and host relay | ✅ | 3 members free, 8 with Premium or a rewarded ad (same as Android). |
| Connect to PC (browser page) | ✅ | Your same `index.html`, the same API and 6-digit code. Instead of creating a hotspot, the iPhone uses its **Personal Hotspot**. |
| 1 GB per-file limit on the free plan | ✅ | |
| File manager | ✅ | Categories, storage, browser (copy, move, rename, delete, new folder), search, large files, import. Everything is also visible in the **Files app**. |
| File preview | ✅ | QuickLook handles images, video, audio, PDF, text, Office files and ZIP. |
| Music player | ✅ | Background play, lock-screen controls, shuffle and repeat, mini player, ✕ to close. Plays received songs and non-DRM songs in the Music library. |
| Video player | ✅ | Speed from 0.5× to 2×, rotates to landscape, Picture-in-Picture (ad or Premium unlock), videos from Photos and from the app. |
| Converter | ✅ | Images: JPG, PNG, HEIC, compress, resize. PDF: images → PDF, PDF → images, text → PDF. Audio/video: M4A, WAV, MP4, compress to 720p or 480p (with a before → after report), GIF. Batch mode (ad or Premium unlock). |
| Safebox | ✅ | AES-256-GCM in 1 MB chunks, key in the Keychain, PIN (PBKDF2), pattern, Face ID/Touch ID, recovery questions, 10 files free. Can remove the originals from Photos. |
| Clean | ✅ | Duplicate and similar photos (perceptual hash), screenshots, videos over 100 MB, Smart select (ad or Premium unlock), app junk. |
| Premium | ✅ | StoreKit 2 with the same product IDs. Restore. A rewarded ad gives 24 hours of Premium. |
| Ads | ✅ | Banner, native, interstitial, rewarded and app open, with **the same rules as Android**: cooldown, per-session cap, never on app start, never during a transfer or playback. |
| 9 languages | ✅ | String Catalog generated from your Android `values-*/strings.xml`. |
| History, device name and avatar, dark mode, share-to-app | ✅ | "Open in / Copy to Share you" from any app starts a Send. |
| **WhatsApp status saver** | ❌ | iOS apps can't read another app's files. |
| **Video downloader (yt-dlp)** | ❌ | App Store guideline 5.2.3 rejects these, and iOS can't run yt-dlp. |
| **Send installed apps (APK)** | ❌ | iOS has no installable app files. APKs can still be received and passed on. |
| **Notification blocker / notification toolbar** | ❌ | iOS has no API for either. |
| **iPhone creating its own hotspot** | ⚠️ | No API exists. When the iPhone receives, it uses the same Wi-Fi, peer-to-peer (iPhone to iPhone), or the user's Personal Hotspot. |

**Added on iOS:**

- Optional **Sign in with Apple or Google**
- Profile and stats synced to **Firestore**
- In-app account deletion
- Remote Config for a forced update and an ads kill switch
- A setting to save received photos and videos to Photos

---

## 3. Project layout

```
ShareYou.xcodeproj           Xcode 16 project + shared scheme (Run=Debug, Archive=Release)
Config/                      Base / Debug / Release .xcconfig, Secrets.example, Info.plist, entitlements
ShareYou/
  App/                       @main app, AppDelegate (FirebaseApp.configure), DI container, router, root tabs
  Core/                      Config, Firebase (App Check, Crashlytics, FCM, Remote Config), Auth, Firestore,
                             Prefs, history, network monitor, file helpers, logging
  Features/                  Transfer, PC, Files, Player, Converter, Safebox, Clean, Premium, Ads, Home, Settings
  UI/                        Theme (brand colors) + shared components
  Resources/                 Assets, Localizable.xcstrings, GoogleService-Info.plist, PrivacyInfo.xcprivacy, pc_index.html
Firebase/                    firestore.rules, indexes, firebase.json (deploy with the Firebase CLI)
tools/generate_xcodeproj.py  regenerates the .xcodeproj
```

**Architecture:**

- MVVM: SwiftUI views, with `ObservableObject` services and view models on `@MainActor`.
- Dependency injection: services are created once in `AppContainer` and injected with `environmentObject`.
- Debug logs go through `Log.d`, which is compiled out of Release builds. Errors go to Crashlytics.

---

## 4. Setup checklist

### ✅ Set up in this project

- [x] Bundle ID `com.ol.your.mob.send.share.files`, MARKETING_VERSION 1.0.0, CURRENT_PROJECT_VERSION 1, iOS 16.0, iPhone and iPad, portrait on iPhone
- [x] Automatic signing. The Team ID comes from the git-ignored `Secrets.xcconfig`, and no certificates or profiles are committed.
- [x] Debug and Release `.xcconfig` files for every environment value (AdMob IDs, Google client ID, URLs, App Store ID)
- [x] `.gitignore` covers secrets, `.env`, `*.p12`, `*.p8`, `*.mobileprovision` and `GoogleService-Info.plist`. The plist line is commented out; uncomment it if the repository is public.
- [x] **Firebase through SPM** (`firebase-ios-sdk`, version 12 or later). `FirebaseApp.configure()` runs in `AppDelegate`, attached with `@UIApplicationDelegateAdaptor`.
- [x] **GoogleService-Info.plist** (your file, including CLIENT_ID) is in the app target.
- [x] **Crashlytics**, enabled in all builds:
  - dSYMs are generated for Debug and Release.
  - The **Run Script** phase calls `"${BUILD_DIR%/Build/*}/SourcePackages/checkouts/firebase-ios-sdk/Crashlytics/run"` and lists all 6 input files you gave.
  - User script sandboxing is off, as Crashlytics requires.
  - **Settings › Debug › Test crash** runs `fatalError("Crash was triggered")`.
- [x] **Analytics**, with events for transfers, conversions, the paywall, purchases and sign-in
- [x] **Cloud Messaging**:
  - APNs registration and FCM token handling
  - subscription to the topic `shareyou_updates`, the same as Android
  - notification taps open the matching screen (`route` in the data payload)
  - the permission prompt appears after the first finished transfer, never at launch
  - Push and `remote-notification` background mode are configured
- [x] **Remote Config** with defaults for `force_update_version`, `ads_enabled`, `interstitial_cooldown_sec` and `interstitial_session_cap`
- [x] **Authentication**:
  - Sign in with Apple, with a nonce and full name
  - Google Sign-In, with the URL scheme set to REVERSED_CLIENT_ID
  - sign out, and account deletion that revokes the Apple token
- [x] **Firestore**: `users/{uid}` profile and stats. The security rules in `Firebase/firestore.rules` let each user access only their own document and close everything else (no test mode).
- [x] **App Check**: App Attest in Release, DeviceCheck as a fallback, the debug provider in Debug
- [x] **Google Mobile Ads through SPM**:
  - `GADApplicationIdentifier` and the SKAdNetworkItems list are in Info.plist.
  - All ad unit IDs live in one place (the xcconfig files, read by `AdConfig`).
  - Debug uses Google's **test IDs**. Release placeholders are never requested.
  - Formats: banner, native, interstitial, rewarded and app open.
- [x] **UMP consent** (GDPR) is gathered before any ad request. "Ad privacy choices" appears in Settings when required.
- [x] **ATT** is asked after consent, at a calm moment (after the first finished task or in a later session), never as the first screen.
- [x] Interstitials have a frequency cap (60–90 s cooldown, 4–6 per session, 2 actions between them) and are **never shown at app start**.
- [x] **Settings and About**:
  - version and build
  - Privacy Policy and Terms
  - Contact Us (mail composer)
  - Rate Us (App Store review page, or StoreKit's review prompt)
  - Share App
  - More Apps
- [x] Permissions are requested only when needed. Every Info.plist usage string is filled in: camera, Photos, Photos add, Music library, Face ID, local network, tracking.
- [x] `PrivacyInfo.xcprivacy` privacy manifest
- [x] Accessibility and states:
  - String Catalog with 9 languages
  - dark mode, Dynamic Type (system fonts), safe areas, VoiceOver labels
  - offline handling with NWPathMonitor and an offline banner
  - loading, error and empty states
- [x] No `print` calls. Debug logs are stripped from Release builds.

### 🔧 You still need to do these manually

1. **Apple Developer › Identifiers › `com.ol.your.mob.send.share.files`**: enable **Push Notifications**, **Sign in with Apple**, **App Attest** and **Hotspot Configuration**. Xcode's automatic signing then picks up the capabilities from the entitlements file.
2. **APNs key**: Apple Developer › Keys › create a key with APNs (download the `.p8`). Upload it in Firebase Console › Project settings › Cloud Messaging › Apple app configuration, together with the Key ID and Team ID.
3. **Firebase Console**:
   - Authentication › Sign-in method: enable **Google** and **Apple**. For Apple, add your Services ID and the redirect URL `https://yourmob-send-share-files.firebaseapp.com/__/auth/handler`.
   - **Firestore**: create the database, then deploy the rules with `cd Firebase && npx -y firebase-tools@latest deploy --only firestore`.
   - **App Check**: register the iOS app with App Attest. Add the debug token from the Xcode console (Debug builds) under Manage debug tokens. Turn on **Enforce** for Firestore only after TestFlight testing.
   - Crashlytics: run the app once and trigger the test crash so the dashboard activates.
   - Remote Config: publish the four keys if you want to change the defaults.
4. **AdMob**:
   - Create the iOS app and its 5 ad units.
   - Put the real IDs in `Config/Secrets.Release.xcconfig`, following the template.
   - Set up the GDPR message under Privacy & messaging, and the IDFA explainer if you want one.
   - Add `app-ads.txt` to your developer website.
5. **App Store Connect**:
   - Create the app with this bundle ID.
   - Monetization: create the subscription group "Premium" with `zapshare_premium_monthly` and `zapshare_premium_yearly`, plus the non-consumable `zapshare_premium_lifetime`. Fill in the prices and review screenshots.
   - Agreements, Tax and Banking must be active before purchases work.
6. Put your **support email** and **App Store ID** in `Secrets.xcconfig`, and optionally a **More Apps** URL in `Base.xcconfig`.
7. **App Privacy** (nutrition label): declare these to match `PrivacyInfo.xcprivacy`:
   - crash data and product interaction (not linked to the user)
   - email, name and user ID (linked, for app functionality, only when the user signs in)
   - device ID for third-party advertising (tracking, through AdMob)
8. **Age rating** questionnaire, category (Utilities), and **screenshots** for 6.9", 6.5" and 13" iPad.
9. **Review notes**:
   - Transfers need two devices.
   - Explain the Hotspot Configuration entitlement: it joins the other phone's offline hotspot from a scanned QR code.
   - Provide a sandbox account for purchases.
10. **Archive**: select Any iOS Device › Product › Archive › Organizer › Distribute App › App Store Connect. Then use TestFlight, then submit for review.

### 💡 Possible next steps

- A Share Extension, so "Share you" shows in the share sheet's top row (today it appears under "Copy to / Open in").
- Unit tests for the wire protocol (`HostInfo` parse/encode, frame encoding) and for `Vault` encrypt/decrypt.
- Live Activity for transfer progress on the Lock Screen.
