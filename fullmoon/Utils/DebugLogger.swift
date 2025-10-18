//
//  DebugLogger.swift
//  fullmoon
//
//  Created by Claude Code on 18/10/25.
//

import Foundation

class DebugLogger {
    static let shared = DebugLogger()
    private let logFileURL: URL

    init() {
        // Use Documents directory so it's accessible via Files app
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        logFileURL = documentsPath.appendingPathComponent("crash_debug.log")

        // Start fresh log on app launch
        let header = """
        ========================================
        App launched at \(Date())
        ========================================

        """
        try? header.write(to: logFileURL, atomically: true, encoding: .utf8)
    }

    func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())
        let logLine = "[\(timestamp)] \(message)\n"

        // Append to file synchronously to ensure it's written before any crash
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

        // Also print to console
        print(logLine, terminator: "")
    }

    func getLogFilePath() -> String {
        return logFileURL.path
    }
}
