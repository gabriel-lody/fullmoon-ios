//
//  DebugLogger.swift
//  fullmoon
//
//  Created by Claude Code on 18/10/25.
//

import Foundation
import os.log
import os.signpost

class DebugLogger {
    static let shared = DebugLogger()
    private let logFileURL: URL

    // OSLog for system-level logging (survives crashes, integrates with Instruments)
    private let osLog = OSLog(subsystem: "com.github.gabriel-lody.fullmoon-ios", category: "MLX")
    private let signpostLog = OSLog(subsystem: "com.github.gabriel-lody.fullmoon-ios", category: .pointsOfInterest)

    // Track active signpost IDs
    private var activeSignposts: [String: OSSignpostID] = [:]
    private let signpostQueue = DispatchQueue(label: "com.fullmoon.signpost")

    init() {
        // Use Documents directory so it's accessible via Files app
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

        // Create filename with timestamp for each app launch
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: Date())
        let filename = "crash_debug_\(timestamp).log"

        logFileURL = documentsPath.appendingPathComponent(filename)

        // Start fresh log on app launch
        let header = """
        ========================================
        App launched at \(Date())
        Build: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")
        ========================================

        """
        try? header.write(to: logFileURL, atomically: true, encoding: .utf8)

        // Setup signal handlers to catch crashes and log before termination
        setupSignalHandlers()
    }

    // MARK: - Signal Handler Setup (catches crashes before termination)

    private func setupSignalHandlers() {
        // Register handlers for common crash signals
        signal(SIGABRT) { signal in
            DebugLogger.shared.logCrashSignal("SIGABRT", signal: signal)
        }
        signal(SIGSEGV) { signal in
            DebugLogger.shared.logCrashSignal("SIGSEGV", signal: signal)
        }
        signal(SIGBUS) { signal in
            DebugLogger.shared.logCrashSignal("SIGBUS", signal: signal)
        }
        signal(SIGILL) { signal in
            DebugLogger.shared.logCrashSignal("SIGILL", signal: signal)
        }
        signal(SIGFPE) { signal in
            DebugLogger.shared.logCrashSignal("SIGFPE", signal: signal)
        }

        // Also catch uncaught exceptions
        NSSetUncaughtExceptionHandler { exception in
            DebugLogger.shared.logUncaughtException(exception)
        }
    }

    private func logCrashSignal(_ signalName: String, signal: Int32) {
        // CRITICAL: This must be async-safe (no memory allocation, no Swift runtime)
        // We can only use basic C functions here
        let message = "🔴🔴🔴 CRASH SIGNAL: \(signalName) (\(signal)) 🔴🔴🔴\n"
        let cString = message.cString(using: .utf8)
        write(STDERR_FILENO, cString, strlen(cString ?? ""))

        // Force flush any pending logs
        fsync(STDERR_FILENO)
    }

    private func logUncaughtException(_ exception: NSException) {
        let message = """
        🔴🔴🔴 UNCAUGHT EXCEPTION 🔴🔴🔴
        Name: \(exception.name.rawValue)
        Reason: \(exception.reason ?? "unknown")
        Stack: \(exception.callStackSymbols.joined(separator: "\n"))
        """
        log(message)
    }

    // MARK: - Multi-Level Logging

    func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())
        let logLine = "[\(timestamp)] \(message)\n"

        // 1. File logging (survives crashes, accessible via Files app)
        if let handle = try? FileHandle(forWritingTo: logFileURL) {
            handle.seekToEndOfFile()
            if let data = logLine.data(using: .utf8) {
                handle.write(data)
            }
            try? handle.synchronize() // Force write to disk
            try? handle.close()
        } else {
            try? logLine.write(to: logFileURL, atomically: true, encoding: .utf8)
        }

        // 2. OSLog (integrates with Instruments, survives crashes)
        os_log("%{public}@", log: osLog, type: .default, message)

        // 3. Console output
        print(logLine, terminator: "")
    }

    // Enhanced logging with memory info
    func logWithMemory(_ message: String) {
        let memInfo = getMemoryInfo()
        let fullMessage = "\(message) | Mem: \(memInfo)"
        log(fullMessage)
    }

    func logWithStack(_ message: String) {
        // Log the message first
        log(message)

        // Capture and log the call stack
        let stackSymbols = Thread.callStackSymbols
        log("  Stack trace:")
        for (index, symbol) in stackSymbols.enumerated() {
            // Skip the first 2 frames (this function and the caller)
            if index < 2 { continue }
            // Only log first 10 frames to avoid excessive output
            if index > 12 {
                log("  ... (\(stackSymbols.count - index) more frames)")
                break
            }
            log("    [\(index-1)] \(symbol)")
        }
    }

    // MARK: - os_signpost Integration (for Instruments)

    func beginSignpost(_ name: String, metadata: String = "") {
        signpostQueue.async {
            let signpostID = OSSignpostID(log: self.signpostLog)
            self.activeSignposts[name] = signpostID

            if metadata.isEmpty {
                os_signpost(.begin, log: self.signpostLog, name: StaticString(name.utf8Start!), signpostID: signpostID)
            } else {
                os_signpost(.begin, log: self.signpostLog, name: StaticString(name.utf8Start!), signpostID: signpostID, "%{public}@", metadata)
            }
        }
        log("▶️ BEGIN: \(name) \(metadata)")
    }

    func endSignpost(_ name: String, metadata: String = "") {
        signpostQueue.async {
            guard let signpostID = self.activeSignposts[name] else {
                return
            }

            if metadata.isEmpty {
                os_signpost(.end, log: self.signpostLog, name: StaticString(name.utf8Start!), signpostID: signpostID)
            } else {
                os_signpost(.end, log: self.signpostLog, name: StaticString(name.utf8Start!), signpostID: signpostID, "%{public}@", metadata)
            }

            self.activeSignposts.removeValue(forKey: name)
        }
        log("⏹️ END: \(name) \(metadata)")
    }

    func eventSignpost(_ name: String, metadata: String = "") {
        os_signpost(.event, log: signpostLog, name: StaticString(name.utf8Start!), "%{public}@", metadata)
        log("📍 EVENT: \(name) \(metadata)")
    }

    // MARK: - Memory Monitoring

    private func getMemoryInfo() -> String {
        var taskInfo = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &taskInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }

        if result == KERN_SUCCESS {
            let usedMB = Double(taskInfo.resident_size) / 1024.0 / 1024.0
            return String(format: "%.1fMB", usedMB)
        }
        return "N/A"
    }

    func logMemoryPressure() {
        let memInfo = getMemoryInfo()
        log("💾 Memory: \(memInfo)")

        // Also log to OSLog with .info level for better filtering
        os_log("Memory: %{public}@", log: osLog, type: .info, memInfo)
    }

    // MARK: - Utilities

    func getLogFilePath() -> String {
        return logFileURL.path
    }
}

// Helper extension for StaticString conversion
extension String {
    var utf8Start: UnsafePointer<Int8>? {
        return (self as NSString).utf8String
    }
}
