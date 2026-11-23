import Foundation
import UIKit
import FirebaseAnalytics

/// Pings the main thread. If it does not answer, logs `app_not_responding`.
final class AnrMonitor: @unchecked Sendable {
    static let shared = AnrMonitor()

    private let lock = NSLock()
    private var _screen = "launch"
    private var _foreground = true
    private var started = false

    var currentScreen: String {
        get { lock.lock(); defer { lock.unlock() }; return _screen }
        set { lock.lock(); _screen = newValue; lock.unlock() }
    }

    func start() {
        guard !started else { return }
        started = true
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
            self?.lock.lock(); self?._foreground = true; self?.lock.unlock()
        }
        nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: nil) { [weak self] _ in
            self?.lock.lock(); self?._foreground = false; self?.lock.unlock()
        }
        Thread.detachNewThread { [weak self] in self?.loop() }
    }

    private func foreground() -> Bool { lock.lock(); defer { lock.unlock() }; return _foreground }

    private func loop() {
        Thread.current.name = "ShareYou.ANRWatchdog"
        while true {
            Thread.sleep(forTimeInterval: 1)
            guard foreground() else { continue }
            let answered = DispatchSemaphore(value: 0)
            let started = Date()
            DispatchQueue.main.async { answered.signal() }
            if answered.wait(timeout: .now() + 2) == .timedOut {
                let screen = currentScreen
                _ = answered.wait(timeout: .now() + 60)
                let duration = Date().timeIntervalSince(started)
                guard foreground() else { continue }
                Analytics.logEvent("app_not_responding", parameters: [
                    "screen": screen,
                    "duration_sec": duration
                ])
            }
        }
    }
}
