import Foundation
import os

enum Log {
    static let app = Logger(subsystem: "co.nozomi.flow", category: "app")
    static let audio = Logger(subsystem: "co.nozomi.flow", category: "audio")
    static let asr = Logger(subsystem: "co.nozomi.flow", category: "asr")
    static let format = Logger(subsystem: "co.nozomi.flow", category: "format")
    static let insert = Logger(subsystem: "co.nozomi.flow", category: "insert")
    static let hotkey = Logger(subsystem: "co.nozomi.flow", category: "hotkey")
    static let ui = Logger(subsystem: "co.nozomi.flow", category: "ui")
}
