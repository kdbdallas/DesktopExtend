import os

/// Everything this app does touches system state that is awkward to observe
/// after the fact, so each step reports to the unified log.
///
///   log stream --predicate 'subsystem == "com.port21.DesktopExtend"'
enum Log {
    static let general = Logger(subsystem: "com.port21.DesktopExtend", category: "general")
    static let display = Logger(subsystem: "com.port21.DesktopExtend", category: "display")
    static let capture = Logger(subsystem: "com.port21.DesktopExtend", category: "capture")
}
