//
//  AdminShell.swift
//  RebesCore
//
//  Runs shell commands with administrator privileges through
//  `osascript -e 'do shell script … with administrator privileges'`
//  (macOS admin password prompt). Uses a Process instead of NSAppleScript
//  so it is safe to call from any thread and exit codes are surfaced.
//

import Foundation

public enum AdminShell {
    /// POSIX single-quote escaping, safe for paths containing spaces or quotes.
    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public struct Result: Sendable {
        public let ok: Bool
        public let output: String
    }

    /// Runs `command` as an admin shell script. Blocks the calling thread —
    /// call from a background queue.
    public static func runAsAdmin(_ command: String) -> Result {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return runOsascript("do shell script \"\(escaped)\" with administrator privileges")
    }

    /// Runs an arbitrary AppleScript source via /usr/bin/osascript.
    public static func runOsascript(_ source: String) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        do {
            try process.run()
        } catch {
            return Result(ok: false, output: error.localizedDescription)
        }

        // Read to EOF before waiting to avoid pipe-buffer deadlock.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let combined = [outData, errData]
            .compactMap { String(data: $0, encoding: .utf8) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(ok: process.terminationStatus == 0, output: combined)
    }
}
