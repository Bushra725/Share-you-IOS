# Share you iOS — Xcode production build

Folder: `ShareYou-iOS-1.0.0-production`  
Bundle ID: `com.ol.your.mob.send.share.files`  
Version: `1.0.0` (build `1`)

## Already configured in this package

| Item | Value |
|---|---|
| Support email | `hello@theoccess.com` |
| AdMob App ID | `ca-app-pub-9297250663056879~7637998540` |
| Banner | `.../3058343877` |
| Interstitial | `.../4803951640` |
| Rewarded | `.../1755116471` |
| App Open | `.../5283297946` |
| Native | `.../1152481245` |
| Firebase | `yourmob-send-share-files` + `GoogleService-Info.plist` |
| IAP product IDs | `zapshare_premium_monthly`, `zapshare_premium_yearly`, `zapshare_premium_lifetime` |
| More Apps | https://apps.apple.com/us/developer/occess-studio-llc/id1767799636 |
| App Store ID | Not set yet (Rate Us / Share App stay disabled until you add it) |

Secrets live in:

- `Config/Secrets.xcconfig`
- `Config/Secrets.Release.xcconfig`

## You must do once before Archive

### 1. Apple Team ID (required — blocking)

`DEVELOPMENT_TEAM` is currently **empty**.  
“Occess studio llc” is the company name, not the Team ID.

1. Open [developer.apple.com/account](https://developer.apple.com/account) → Membership details  
2. Copy the **Team ID** (10 characters, e.g. `A1B2C3D4E5`)  
3. Paste it into `Config/Secrets.xcconfig`:

```
DEVELOPMENT_TEAM = A1B2C3D4E5
```

Or in Xcode: target **ShareYou** → Signing & Capabilities → Team → Occess studio llc (Xcode fills the Team ID).

### 2. Apple Developer capabilities

For identifier `com.ol.your.mob.send.share.files`, enable:

- Push Notifications  
- Sign in with Apple  
- App Attest  
- Hotspot Configuration  

### 3. App Store Connect

1. Create the iOS app with the same bundle ID  
2. Create IAP products with the three IDs above (subscription group **Premium** + lifetime non-consumable)  
3. After the app exists, put the numeric Apple ID into `Config/Secrets.xcconfig` as `APP_STORE_ID`  
4. Optionally set `MORE_APPS_URL` in `Config/Base.xcconfig`

### 4. Firebase (same project as Android)

- Auth: enable Google + Apple  
- Upload APNs `.p8` key under Cloud Messaging  
- Deploy Firestore rules from `Firebase/`  
- App Check: register App Attest for this iOS app  

### 5. AdMob

IDs are already wired for Release. In AdMob console, confirm the iOS app uses App ID `~7637998540` and the five units above. Set up Privacy & messaging (UMP/GDPR).

## Build in Xcode (Mac)

1. Copy this whole folder to the Mac  
2. Set `DEVELOPMENT_TEAM` (step 1)  
3. Open `ShareYou.xcodeproj` (Xcode 16+)  
4. Wait for SPM packages (Firebase, Google Sign-In, Google Mobile Ads, UMP)  
5. Select a real iPhone → Run (Debug uses Google test ad IDs)  
6. For store build: Any iOS Device → **Product → Archive** → Distribute → App Store Connect  

Debug = test ads. Archive/Release = your real AdMob IDs.

## After first App Store listing

Update `Config/Secrets.xcconfig`:

```
APP_STORE_ID = <numeric Apple ID from App Store Connect>
```

Optional in `Config/Base.xcconfig`:

```
MORE_APPS_URL = https:/$()/apps.apple.com/us/developer/occess-studio-llc/id1767799636
```

