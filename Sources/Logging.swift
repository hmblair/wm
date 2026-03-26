import os

private let logger = Logger(subsystem: "com.hmblair.focus-follows-mouse", category: "general")

private func emit(_ msg: String, level: OSLogType = .info) {
    logger.log(level: level, "\(msg, privacy: .public)")
    if verbose { fputs("[tick \(tickNumber)] \(msg)\n", stderr) }
}

func log(_ message: @autoclosure () -> String) { emit(message()) }
func warn(_ message: @autoclosure () -> String) { emit(message(), level: .error) }
