import SwiftUI
import Lottie

/// Launch splash matching Android `LaunchSplash`:
/// 1) App icon springs in
/// 2) Lottie `splash_name` plays and drives the "Share you" pop
struct SplashView: View {
    @State private var iconScale: CGFloat = 0.84
    @State private var iconAlpha: Double = 0
    @State private var playbackMode: LottiePlaybackMode = .paused(at: .progress(0))
    @State private var nameProgress: AnimationProgressTime = 0
    @State private var playName = false

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()

            // Logo sits on the true center of the screen.
            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 104, height: 104)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .shadow(color: Brand.cyan3.opacity(0.28), radius: 18, y: 8)
                .scaleEffect(iconScale)
                .opacity(iconAlpha)
                .accessibilityHidden(true)

            // App name is directly under the logo. The Lottie clip drives the pop.
            ZStack {
                LottieView(animation: .named("splash_name"))
                    .playbackMode(playbackMode)
                    .getRealtimeAnimationProgress(playName ? $nameProgress : nil)
                    .frame(maxWidth: .infinity)
                    .frame(height: 72)
                    .opacity(0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                Text("Share you")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Color(hex: 0x1A1A1A))
                    .scaleEffect(playName ? namePop(nameProgress) : 0.2)
                    .opacity(playName ? nameAlpha(nameProgress) : 0)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 72)
            .offset(y: 104)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Share you"))
        .task { await runIntro() }
    }

    private func runIntro() async {
        withAnimation(.easeOut(duration: 0.28)) { iconAlpha = 1 }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.70)) { iconScale = 1 }
        try? await Task.sleep(nanoseconds: 360_000_000)
        playName = true
        playbackMode = .playing(.fromProgress(0, toProgress: 1, loopMode: .playOnce))
    }

    /// Pop curve for the app name. Matches Android `namePop` / Lottie scale.
    private func namePop(_ progress: AnimationProgressTime) -> CGFloat {
        let p = CGFloat(min(max(progress, 0), 1))
        if p < 0.45 { return 0.2 + (p / 0.45) * 0.94 }
        if p < 0.68 { return 1.14 - ((p - 0.45) / 0.23) * 0.14 }
        return 1
    }

    private func nameAlpha(_ progress: AnimationProgressTime) -> Double {
        Double(min(max((progress - 0.12) / 0.22, 0), 1))
    }
}
