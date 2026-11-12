import SwiftUI

enum AppTab: Hashable { case home, files, player, tools, me }

/// Screens reachable with NavigationLink(value:) from any tab.
enum Route: Hashable {
    case send, receive(group: Bool), group, connect(group: Bool), pc
    case history, settings, account, about
    case safebox, converter, clean
    case category(FileCategory), browser(URL), largeFiles
    case music, videos
}

/// Navigation state. Each tab keeps its own stack.
@MainActor
final class Router: ObservableObject {
    static let shared = Router()

    @Published var tab: AppTab = .home
    @Published var homePath = NavigationPath()
    @Published var filesPath = NavigationPath()
    @Published var playerPath = NavigationPath()
    @Published var toolsPath = NavigationPath()
    @Published var mePath = NavigationPath()

    @Published var showPaywall = false
    @Published var toast: String?

    private init() {}

    /// Push a route on the stack of the current tab.
    func push(_ route: Route) {
        switch tab {
        case .home: homePath.append(route)
        case .files: filesPath.append(route)
        case .player: playerPath.append(route)
        case .tools: toolsPath.append(route)
        case .me: mePath.append(route)
        }
    }

    func popToRoot() {
        switch tab {
        case .home: homePath = NavigationPath()
        case .files: filesPath = NavigationPath()
        case .player: playerPath = NavigationPath()
        case .tools: toolsPath = NavigationPath()
        case .me: mePath = NavigationPath()
        }
    }

    func paywall() {
        AnalyticsService.log(.paywallShown)
        showPaywall = true
    }

    func showToast(_ text: String) {
        toast = text
        Task {
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            if toast == text { toast = nil }
        }
    }

    /// A file opened in / shared to Share you from another app: stage it and start a send.
    func handleIncoming(url: URL) {
        guard url.isFileURL else {
            if url.scheme == "shareyou" { openDeepLink(url.host ?? "") }
            return
        }
        do {
            let staged = try AppFiles.stage(url)
            SelectionStore.shared.add(ShareItem(url: staged))
            tab = .home
            homePath = NavigationPath()
            homePath.append(Route.send)
        } catch {
            Log.e("Could not open shared file", error)
            showToast(String(localized: "Could not open that file."))
        }
    }

    /// Push-notification / URL deep link: "receive", "send", "pc", "premium", "safebox", "converter", "clean".
    func openDeepLink(_ route: String) {
        switch route.lowercased() {
        case "premium": paywall()
        case "receive": tab = .home; homePath.append(Route.receive(group: false))
        case "send": tab = .home; homePath.append(Route.send)
        case "pc": tab = .home; homePath.append(Route.pc)
        case "safebox": tab = .tools; toolsPath.append(Route.safebox)
        case "converter": tab = .tools; toolsPath.append(Route.converter)
        case "clean": tab = .tools; toolsPath.append(Route.clean)
        case "files": tab = .files
        case "player": tab = .player
        default: break
        }
    }
}
