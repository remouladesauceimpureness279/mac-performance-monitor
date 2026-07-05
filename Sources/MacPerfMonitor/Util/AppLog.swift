import os

/// Centralised loggers. Evidence lines that must survive until a later `log
/// show` query use `.notice` (persisted), not `.info` (ring-buffer only).
enum AppLog {
    static let subsystem = "uk.co.bzwrd.macperfmonitor"
    static let sampler = Logger(subsystem: subsystem, category: "sampler")
    static let ui = Logger(subsystem: subsystem, category: "ui")
    static let alerts = Logger(subsystem: subsystem, category: "alerts")
    static let helper = Logger(subsystem: subsystem, category: "helper")
}
