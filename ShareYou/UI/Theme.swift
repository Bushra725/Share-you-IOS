import SwiftUI
import UIKit

/// Brand palette — the same colors as the Android app (#28D4FF / #16C9F6 / #00C6F8).
enum Brand {
    static let cyan1 = Color(hex: 0x28D4FF)
    static let cyan2 = Color(hex: 0x16C9F6)
    static let cyan3 = Color(hex: 0x00C6F8)
    static let navy = Color(hex: 0x002B3A)
    static let cyanInk = Color(hex: 0x007FA6)
    static let gold = Color(hex: 0xFFC83D)

    static let catMusic = Color(hex: 0xFF5A5F)
    static let catApps = Color(hex: 0x3D8BFF)
    static let catVideo = Color(hex: 0x8B5CF6)
    static let catPhoto = Color(hex: 0x22C55E)
    static let catDocs = Color(hex: 0xF59E0B)
    static let catPdf = Color(hex: 0xEF4444)
    static let catSafe = Color(hex: 0x10B981)
    static let catDownload = Color(hex: 0x6366F1)
    static let catPink = Color(hex: 0xEC4899)
    static let catCyan = Color(hex: 0x06B6D4)

    static let gradient = LinearGradient(colors: [cyan1, cyan2, cyan3], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let tileGradient = LinearGradient(colors: [cyan1, cyan3, Color(hex: 0x0094D4)], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let premiumGradient = LinearGradient(colors: [Color(hex: 0x0B2530), Color(hex: 0x004E66)], startPoint: .leading, endPoint: .trailing)

    /// Card background that adapts to light / dark mode.
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let background = Color(uiColor: .systemGroupedBackground)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

/// Rectangle with only the bottom corners rounded (works on iOS 16).
struct BottomRoundedShape: Shape {
    var radius: CGFloat
    func path(in rect: CGRect) -> Path {
        Path(UIBezierPath(roundedRect: rect, byRoundingCorners: [.bottomLeft, .bottomRight],
                          cornerRadii: CGSize(width: radius, height: radius)).cgPath)
    }
}
