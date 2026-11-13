import SwiftUI
import StoreKit

struct PaywallView: View {
    @EnvironmentObject private var store: StoreService
    @EnvironmentObject private var ads: AdsManager
    @EnvironmentObject private var network: NetworkMonitor
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var selected = StoreService.yearly
    @State private var adError: String?

    private struct Feature: Identifiable {
        let icon: String
        let text: LocalizedStringKey
        var id: String { icon }
    }

    private let features: [Feature] = [
        Feature(icon: "infinity", text: "Send files of any size (free: up to 1 GB each)"),
        Feature(icon: "nosign", text: "No ads, ever"),
        Feature(icon: "lock.shield.fill", text: "Safebox: hide private photos, videos & files"),
        Feature(icon: "arrow.triangle.2.circlepath", text: "Image compressor and audio/video converter"),
        Feature(icon: "pip.fill", text: "Background playback and Picture-in-Picture"),
        Feature(icon: "person.3.fill", text: "Group share with up to 8 phones"),
        Feature(icon: "heart.fill", text: "Support future features")
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Circle().fill(Brand.gold).frame(width: 84, height: 84)
                        .overlay(Image(systemName: "crown.fill").font(.system(size: 38)).foregroundStyle(Brand.navy))
                        .padding(.top, 8)
                    Text("Share you Premium").font(.title.bold())
                    if store.isPremium {
                        Label(store.statusLabel, systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    }
                    SectionCard {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(features) { f in
                                Label { Text(f.text) } icon: { Image(systemName: f.icon).foregroundStyle(Brand.cyan3) }
                            }
                        }
                    }
                    OfflineBanner()
                    plans
                    if store.loadingProducts {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Loading plans from the App Store…").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    if let message = store.message {
                        Text(message).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                    }
                    Button {
                        Task {
                            await store.purchase(productID: selected)
                            if store.isPremium { dismiss() }
                        }
                    } label: {
                        HStack {
                            if store.purchasing || store.loadingProducts { ProgressView().tint(Brand.navy) }
                            Text(store.product(selected) == nil ? "Retry & Continue" : "Continue")
                        }
                        .frame(maxWidth: .infinity)
                        .opacity(store.purchasing ? 0.7 : 1)
                    }
                    .buttonStyle(BrandButtonStyle())
                    .disabled(store.purchasing || store.loadingProducts)
                    .accessibilityHint(Text("Starts the App Store purchase for the selected plan"))

                    if !store.isPremium {
                        Button {
                            ads.showRewarded(onReward: {
                                store.grantFromAd()
                                dismiss()
                            }, onUnavailable: { adError = $0 })
                        } label: {
                            Label("Watch a video for 24 hours of Premium", systemImage: "play.rectangle")
                        }
                        if let adError { Text(adError).font(.footnote).foregroundStyle(.red) }
                    }

                    Button("Restore purchases") { Task { await store.restore() } }
                        .font(.subheadline)

                    Text("Subscriptions renew automatically unless cancelled at least 24 hours before the end of the current period. Your Apple ID is charged for renewal within 24 hours before the end of the period. Manage or cancel in Settings › Apple ID › Subscriptions. Lifetime is a one-time purchase.")
                        .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    HStack(spacing: 16) {
                        Button("Terms of Use") { openURL(AppConfig.termsURL) }
                        Button("Privacy policy") { openURL(AppConfig.privacyPolicyURL) }
                    }
                    .font(.caption)
                }
                .padding()
            }
            .background(Brand.background)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(Text("Close"))
                }
            }
            .task { if store.products.isEmpty { await store.loadProducts() } }
        }
    }

    private var plans: some View {
        VStack(spacing: 10) {
            planRow(StoreService.monthly, title: "Monthly", fallback: "$1.99", best: false)
            planRow(StoreService.yearly, title: "Yearly", fallback: "$9.99", best: true)
            planRow(StoreService.lifetime, title: "Lifetime", fallback: "$19.99", best: false)
        }
    }

    private func planRow(_ id: String, title: LocalizedStringKey, fallback: String, best: Bool) -> some View {
        let product = store.product(id)
        let isSelected = selected == id
        return Button { selected = id } label: {
            HStack {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle").foregroundStyle(Brand.cyan3)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(title).font(.headline)
                        if best {
                            Text("BEST VALUE").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Brand.gold, in: Capsule()).foregroundStyle(Brand.navy)
                        }
                    }
                    if let period = product?.subscription?.subscriptionPeriod {
                        Text(periodText(period)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(product?.displayPrice ?? fallback).font(.headline)
            }
            .padding()
            .background(Brand.card, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(isSelected ? Brand.cyan3 : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func periodText(_ p: Product.SubscriptionPeriod) -> String {
        switch p.unit {
        case .month: return p.value == 1 ? String(localized: "per month") : String(localized: "every \(p.value) months")
        case .year: return String(localized: "per year")
        case .week: return String(localized: "per week")
        case .day: return String(localized: "every \(p.value) days")
        @unknown default: return ""
        }
    }
}
