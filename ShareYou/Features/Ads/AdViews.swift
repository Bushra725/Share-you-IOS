import SwiftUI
import GoogleMobileAds

/// Adaptive anchored banner. Hidden for Premium users and when ads cannot be requested.
struct AdBanner: View {
    @EnvironmentObject private var ads: AdsManager
    @EnvironmentObject private var store: StoreService
    @EnvironmentObject private var router: Router
    @State private var loaded = false

    var body: some View {
        if !ads.adsOff && AdConfig.usable(AdConfig.banner) {
            VStack(spacing: 4) {
                GeometryReader { geo in
                    BannerRepresentable(width: geo.size.width, loaded: $loaded)
                }
                .frame(height: loaded ? 60 : 0)
                if loaded {
                    Button("Remove ads") { router.paywall() }.font(.caption2)
                }
            }
        }
    }
}

private struct BannerRepresentable: UIViewRepresentable {
    let width: CGFloat
    @Binding var loaded: Bool

    func makeCoordinator() -> Coordinator { Coordinator(loaded: $loaded) }

    func makeUIView(context: Context) -> BannerView {
        let banner = BannerView(adSize: currentOrientationAnchoredAdaptiveBanner(width: max(width, 320)))
        banner.adUnitID = AdConfig.banner
        banner.rootViewController = UIHelpers.topViewController()
        banner.delegate = context.coordinator
        banner.load(Request())
        return banner
    }

    func updateUIView(_ banner: BannerView, context: Context) {}

    @MainActor final class Coordinator: NSObject, BannerViewDelegate {
        @Binding var loaded: Bool
        init(loaded: Binding<Bool>) { _loaded = loaded }
        func bannerViewDidReceiveAd(_ bannerView: BannerView) { loaded = true }
        func bannerView(_ bannerView: BannerView, didFailToReceiveAdWithError error: Error) { loaded = false }
    }
}

/// Native ad card for Home (Android's NativeAdCard), built in code — no XIB.
struct NativeAdCard: View {
    @EnvironmentObject private var ads: AdsManager
    @StateObject private var loader = NativeAdLoader()

    var body: some View {
        if !ads.adsOff, AdConfig.usable(AdConfig.native) {
            Group {
                if let ad = loader.ad {
                    NativeAdRepresentable(ad: ad)
                        .frame(height: 300)
                        .background(Brand.card, in: RoundedRectangle(cornerRadius: 20))
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                }
            }
            .onAppear { loader.load() }
        }
    }
}

@MainActor
final class NativeAdLoader: NSObject, ObservableObject, NativeAdLoaderDelegate {
    @Published var ad: NativeAd?
    private var adLoader: AdLoader?

    func load() {
        guard adLoader == nil, ad == nil else { return }
        let loader = AdLoader(adUnitID: AdConfig.native, rootViewController: UIHelpers.topViewController(),
                              adTypes: [.native], options: nil)
        loader.delegate = self
        adLoader = loader
        loader.load(Request())
    }

    nonisolated func adLoader(_ adLoader: AdLoader, didReceive nativeAd: NativeAd) {
        Task { @MainActor in self.ad = nativeAd }
    }

    nonisolated func adLoader(_ adLoader: AdLoader, didFailToReceiveAdWithError error: Error) {
        Task { @MainActor in self.adLoader = nil }
    }
}

private struct NativeAdRepresentable: UIViewRepresentable {
    let ad: NativeAd

    func makeUIView(context: Context) -> NativeAdView {
        let view = NativeAdView()

        let badge = UILabel()
        badge.text = "Ad"
        badge.font = .preferredFont(forTextStyle: .caption2)
        badge.textColor = .white
        badge.backgroundColor = UIColor(red: 0.96, green: 0.62, blue: 0.04, alpha: 1)
        badge.layer.cornerRadius = 4
        badge.clipsToBounds = true
        badge.textAlignment = .center

        let icon = UIImageView()
        icon.contentMode = .scaleAspectFit
        icon.layer.cornerRadius = 8
        icon.clipsToBounds = true

        let headline = UILabel()
        headline.font = .preferredFont(forTextStyle: .headline)
        headline.adjustsFontForContentSizeCategory = true
        headline.numberOfLines = 2

        let body = UILabel()
        body.font = .preferredFont(forTextStyle: .footnote)
        body.adjustsFontForContentSizeCategory = true
        body.textColor = .secondaryLabel
        body.numberOfLines = 2

        let media = MediaView()
        media.contentMode = .scaleAspectFill
        media.clipsToBounds = true

        let cta = UIButton(type: .system)
        cta.isUserInteractionEnabled = false // the SDK handles the click
        cta.backgroundColor = UIColor(red: 0, green: 0.776, blue: 0.973, alpha: 1)
        cta.setTitleColor(UIColor(red: 0, green: 0.169, blue: 0.227, alpha: 1), for: .normal)
        cta.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        cta.layer.cornerRadius = 10

        [badge, icon, headline, body, media, cta].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            icon.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            icon.widthAnchor.constraint(equalToConstant: 40),
            icon.heightAnchor.constraint(equalToConstant: 40),
            headline.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            headline.trailingAnchor.constraint(equalTo: badge.leadingAnchor, constant: -8),
            headline.topAnchor.constraint(equalTo: icon.topAnchor),
            badge.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            badge.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            badge.widthAnchor.constraint(equalToConstant: 26),
            body.leadingAnchor.constraint(equalTo: headline.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            body.topAnchor.constraint(equalTo: headline.bottomAnchor, constant: 2),
            media.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            media.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            media.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 8),
            media.bottomAnchor.constraint(equalTo: cta.topAnchor, constant: -8),
            cta.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            cta.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            cta.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            cta.heightAnchor.constraint(equalToConstant: 44)
        ])

        view.iconView = icon
        view.headlineView = headline
        view.bodyView = body
        view.mediaView = media
        view.callToActionView = cta
        return view
    }

    func updateUIView(_ view: NativeAdView, context: Context) {
        (view.headlineView as? UILabel)?.text = ad.headline
        (view.bodyView as? UILabel)?.text = ad.body
        (view.iconView as? UIImageView)?.image = ad.icon?.image
        view.iconView?.isHidden = ad.icon == nil
        (view.callToActionView as? UIButton)?.setTitle(ad.callToAction, for: .normal)
        view.callToActionView?.isHidden = ad.callToAction == nil
        view.mediaView?.mediaContent = ad.mediaContent
        view.nativeAd = ad
    }
}
