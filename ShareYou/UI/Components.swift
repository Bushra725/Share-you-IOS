import SwiftUI
import QuickLook
import QuickLookThumbnailing
import MessageUI

// MARK: - Cards & tiles

struct SectionCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

struct ToolItem: Identifiable {
    let id = UUID()
    let icon: String
    let title: LocalizedStringKey
    let color: Color
    var badge: String? = nil
    let action: () -> Void
}

struct ToolTile: View {
    let item: ToolItem
    var body: some View {
        Button(action: item.action) {
            VStack(spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(item.color.opacity(0.14))
                        .frame(width: 52, height: 52)
                        .overlay(Image(systemName: item.icon).font(.title3.weight(.semibold)).foregroundStyle(item.color))
                    if let badge = item.badge {
                        Text(badge).font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Brand.gold, in: Capsule()).foregroundStyle(Brand.navy).offset(x: 8, y: -6)
                    }
                }
                Text(item.title)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

struct TileGrid: View {
    let items: [ToolItem]
    var columns = 4
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: columns), spacing: 8) {
            ForEach(items) { ToolTile(item: $0) }
        }
    }
}

struct BrandIconBox: View {
    let systemName: String
    var size: CGFloat = 44
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(Brand.tileGradient)
            .frame(width: size, height: size)
            .overlay(Image(systemName: systemName).font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(Brand.navy))
            .accessibilityHidden(true)
    }
}

struct AvatarBubble: View {
    let index: Int
    var size: CGFloat = 44
    var ring = false
    var body: some View {
        Text(Prefs.avatars[max(0, min(index, Prefs.avatars.count - 1))])
            .font(.system(size: size * 0.55))
            .frame(width: size, height: size)
            .background(Circle().fill(Color.white.opacity(0.9)))
            .overlay(Circle().stroke(Color.white, lineWidth: ring ? 3 : 0))
            .accessibilityHidden(true)
    }
}

struct PremiumBanner: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Circle().fill(Brand.gold).frame(width: 46, height: 46)
                    .overlay(Image(systemName: "crown.fill").foregroundStyle(Brand.navy))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Go Premium").font(.headline).foregroundStyle(.white)
                    Text("Unlimited file size • No ads • Safebox").font(.caption).foregroundStyle(.white.opacity(0.8))
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.white)
            }
            .padding(16)
            .background(Brand.premiumGradient, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Rewarded unlock

enum UnlockState { case locked, unlockedToday, premium }

struct UnlockPill: View {
    let state: UnlockState
    var body: some View {
        let (text, icon, bg, fg): (LocalizedStringKey, String, Color, Color) = {
            switch state {
            case .locked: return ("Watch ad", "play.circle.fill", Color(hex: 0xFFF0CC), Color(hex: 0x7A4E00))
            case .unlockedToday: return ("Unlocked today", "lock.open.fill", Color(hex: 0xDDF7E8), Color(hex: 0x0F6B38))
            case .premium: return ("Premium", "crown.fill", Color(hex: 0xFFE39A), Color(hex: 0x5E4100))
            }
        }()
        Label(text, systemImage: icon)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(bg, in: Capsule())
            .foregroundStyle(fg)
    }
}

/// Explains exactly what one rewarded ad unlocks (until midnight), with Premium as the permanent option.
struct UnlockSheet: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let icon: String
    let perks: [LocalizedStringKey]
    var onUnlocked: () -> Void
    @EnvironmentObject private var ads: AdsManager
    @EnvironmentObject private var router: Router
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        VStack(spacing: 16) {
            BrandIconBox(systemName: icon, size: 64).padding(.top, 24)
            Text(title).font(.title3.bold()).multilineTextAlignment(.center)
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(perks.enumerated()), id: \.offset) { _, perk in
                    Label(perk, systemImage: "checkmark.circle.fill").foregroundStyle(.primary)
                        .symbolRenderingMode(.multicolor)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let error { Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center) }
            Button {
                loading = true
                ads.showRewarded(onReward: {
                    onUnlocked()
                    dismiss()
                }, onUnavailable: { message in
                    loading = false
                    error = message
                })
            } label: {
                HStack {
                    if loading { ProgressView().tint(Brand.navy) }
                    Label("Watch a short video", systemImage: "play.rectangle.fill")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(BrandButtonStyle())
            Button {
                dismiss()
                router.paywall()
            } label: {
                Label("Get Premium", systemImage: "crown.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            Button("Not now") { dismiss() }.padding(.bottom, 8)
        }
        .padding(.horizontal, 24)
        .presentationDetents([.medium, .large])
    }
}

struct BrandButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Brand.navy)
            .padding(.vertical, 14)
            .padding(.horizontal, 20)
            .background(Brand.gradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

// MARK: - States

struct EmptyStateView: View {
    let icon: String
    let title: LocalizedStringKey
    var message: LocalizedStringKey? = nil
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 44)).foregroundStyle(Brand.cyan3)
            Text(title).font(.headline)
            if let message { Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center) }
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}

struct ErrorBanner: View {
    let text: String
    var onClose: (() -> Void)? = nil
    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
            if let onClose {
                Button(action: onClose) { Image(systemName: "xmark") }
                    .accessibilityLabel(Text("Close"))
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct OfflineBanner: View {
    @EnvironmentObject private var network: NetworkMonitor
    var body: some View {
        if !network.isOnline {
            Label("You're offline. Transfers still work; sign-in, purchases and ads need the internet.", systemImage: "wifi.slash")
                .font(.footnote)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.gray.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

struct ToastView: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.ultraThickMaterial, in: Capsule())
            .shadow(radius: 6)
            .padding(.bottom, 90)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityAddTraits(.updatesFrequently)
    }
}

// MARK: - File thumbnails

struct FileThumb: View {
    let url: URL?
    let name: String
    var size: CGFloat = 44
    @State private var image: UIImage?

    var body: some View {
        let category = FileUtils.categoryOf(mime: FileUtils.mimeOf(name), name: name)
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(category.color.opacity(0.14))
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: category.icon).foregroundStyle(category.color)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityHidden(true)
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        let scale = await MainActor.run { UIScreen.main.scale }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size),
                                                   scale: scale, representationTypes: .thumbnail)
        if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            image = rep.uiImage
        }
    }
}

// MARK: - UIKit bridges

/// System share sheet (UIActivityViewController).
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// QuickLook preview for images, video, audio, PDF, text, Office files, ZIP, etc.
struct QuickLookView: UIViewControllerRepresentable {
    let urls: [URL]
    var index: Int = 0

    func makeCoordinator() -> Coordinator { Coordinator(urls: urls) }

    func makeUIViewController(context: Context) -> UINavigationController {
        let ql = QLPreviewController()
        ql.dataSource = context.coordinator
        ql.currentPreviewItemIndex = index
        return UINavigationController(rootViewController: ql)
    }

    func updateUIViewController(_ vc: UINavigationController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let urls: [URL]
        init(urls: [URL]) { self.urls = urls }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { urls.count }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            urls[index] as NSURL
        }
    }
}

/// Mail composer for "Contact us".
struct MailComposer: UIViewControllerRepresentable {
    let recipient: String
    let subject: String
    let body: String
    @Environment(\.dismiss) private var dismiss

    static var canSend: Bool { MFMailComposeViewController.canSendMail() }

    func makeCoordinator() -> Coordinator { Coordinator(dismiss: { dismiss() }) }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.setToRecipients([recipient])
        vc.setSubject(subject)
        vc.setMessageBody(body, isHTML: false)
        vc.mailComposeDelegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: MFMailComposeViewController, context: Context) {}

    @MainActor final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let dismiss: () -> Void
        init(dismiss: @escaping () -> Void) { self.dismiss = dismiss }
        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            dismiss()
        }
    }
}

/// Topmost view controller, for SDKs that present UIKit screens (ads, Google Sign-In, consent).
@MainActor
enum UIHelpers {
    static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive } ?? UIApplication.shared.connectedScenes.first as? UIWindowScene
        var top = scene?.windows.first { $0.isKeyWindow }?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    static func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}
