import os

private let logger = Logger(subsystem: "com.hmblair.wm", category: "general")

private func emit(_ msg: String, level: OSLogType = .info, alwaysStderr: Bool = false) {
    logger.log(level: level, "\(msg, privacy: .public)")
    if verbose || alwaysStderr { fputs("[tick \(tickNumber)] \(msg)\n", stderr) }
}

func debug(_ message: @autoclosure () -> String) { if verbose { emit(message(), level: .debug) } }
func log(_ message: @autoclosure () -> String) { emit(message()) }
func warn(_ message: @autoclosure () -> String) { emit(message(), level: .error, alwaysStderr: true) }
