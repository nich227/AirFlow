import os

/// One logger per area, all under the app's subsystem.
enum Log {
    static let subsystem = "com.kevster.airflow"
    static let hardware = Logger(subsystem: subsystem, category: "hardware")
    static let helper = Logger(subsystem: subsystem, category: "helper")
    static let control = Logger(subsystem: subsystem, category: "control")
    static let store = Logger(subsystem: subsystem, category: "store")
    static let intelligence = Logger(subsystem: subsystem, category: "intelligence")
}
