import Foundation
import os

/// Lightweight logging facade mirroring the Android AppLogger.
public enum AppLogger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.vauth.vulpine"
    private static let logger = Logger(subsystem: subsystem, category: "Vulpine")

    public static func d(_ tag: String, _ message: String) {
        logger.debug("[\(tag, privacy: .public)] \(message, privacy: .public)")
    }

    public static func i(_ tag: String, _ message: String) {
        logger.info("[\(tag, privacy: .public)] \(message, privacy: .public)")
    }

    public static func w(_ tag: String, _ message: String, _ error: Error? = nil) {
        if let error {
            logger.warning("[\(tag, privacy: .public)] \(message, privacy: .public): \(String(describing: error), privacy: .public)")
        } else {
            logger.warning("[\(tag, privacy: .public)] \(message, privacy: .public)")
        }
    }

    public static func e(_ tag: String, _ message: String, _ error: Error? = nil) {
        if let error {
            logger.error("[\(tag, privacy: .public)] \(message, privacy: .public): \(String(describing: error), privacy: .public)")
        } else {
            logger.error("[\(tag, privacy: .public)] \(message, privacy: .public)")
        }
    }
}
