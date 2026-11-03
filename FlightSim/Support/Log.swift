import os

/// Central loggers. Every module logs through one of these so Console.app can filter by subsystem.
enum Log {
    static let subsystem = "com.joanlouji.tvflightsim"
    static let flight = Logger(subsystem: subsystem, category: "flight")
    static let input = Logger(subsystem: subsystem, category: "input")
    static let world = Logger(subsystem: subsystem, category: "world")
    static let app = Logger(subsystem: subsystem, category: "app")
}
