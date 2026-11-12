import Foundation
import os

/// Logging. Debug messages exist only in Debug builds (compiled out of Release).
/// Errors go to the unified log in Debug and to Crashlytics in every build.
enum Log {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ShareYou", category: "app")

    static func d(_ message: @autoclosure () -> String) {
        #if DEBUG
        let text = message()
        logger.debug("\(text, privacy: .public)")
        #endif
    }

    static func e(_ message: @autoclosure () -> String, _ error: Error? = nil) {
        let base = message()
        let text = error.map { "\(base): \($0.localizedDescription)" } ?? base
        #if DEBUG
        logger.error("\(text, privacy: .public)")
        #endif
        CrashReporter.log(text)
        if let error { CrashReporter.record(error) }
    }
}
