import os

enum Log {
    static let subsystem = "app.roost.Roost"
    static let layout = Logger(subsystem: subsystem, category: "layout")
    static let spaces = Logger(subsystem: subsystem, category: "spaces")
    static let system = Logger(subsystem: subsystem, category: "system")
}
