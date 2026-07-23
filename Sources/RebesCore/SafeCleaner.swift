import Foundation

public enum CleanerError: Error, LocalizedError {
    case pathOutsideWhitelist
    case unallowedRoot
    case deletionFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .pathOutsideWhitelist: return "This path is outside the allowed cleaning locations."
        case .unallowedRoot: return "Refusing to delete a root-level directory."
        case .deletionFailed(let reason): return "Could not move to Trash: \(reason)"
        }
    }
}

public final class SafeCleaner: Sendable {
    public static let shared = SafeCleaner()
    
    public let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
    
    public let whitelistedPrefixes: [String]
    
    public init() {
        self.whitelistedPrefixes = [
            "\(homeDir)/Library/Caches",
            "\(homeDir)/Library/Logs",
            "\(homeDir)/Library/Developer/Xcode/DerivedData",
            "\(homeDir)/.npm/_cacache",
            "\(homeDir)/.cache",
            "\(homeDir)/.bun/install/cache",
            "\(homeDir)/Library/Application Support",
            "\(homeDir)/Library/Preferences",
            "\(homeDir)/Library/Containers",
            "\(homeDir)/Library/LaunchAgents",
            "\(homeDir)/Library/Saved Application State"
        ]
    }
    
    public func isAllowed(path: String) -> Bool {
        // Resolve symlinks in the PARENT chain so a symlinked whitelisted root
        // (e.g. ~/Library/Caches moved to an external drive) can't smuggle
        // deletions outside the intended locations. The final component is
        // deliberately NOT resolved: trashing a symlink trashes the link,
        // not its target, which is safe.
        let raw = URL(fileURLWithPath: path).standardizedFileURL
        let standardized = raw.deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .appendingPathComponent(raw.lastPathComponent).path
        
        if standardized == homeDir { return false }
        if standardized == "\(homeDir)/Library" { return false }
        if standardized == "/System" { return false }
        if standardized == "/Applications" { return false }
        
        if standardized.hasPrefix("/System/") { return false }
        
        let protectedPrefixes = [
            "\(homeDir)/.ssh",
            "\(homeDir)/.gnupg",
            "\(homeDir)/.aws",
            "\(homeDir)/Library/Keychains"
        ]
        for prefix in protectedPrefixes {
            if standardized == prefix || standardized.hasPrefix(prefix + "/") {
                return false
            }
        }
        
        if whitelistedPrefixes.contains(standardized) {
            return false
        }
        
        if standardized.hasPrefix("/Applications/") {
            let components = standardized.components(separatedBy: "/")
            if components.count == 3 && components[2].hasSuffix(".app") {
                return true
            }
            return false
        }
        
        if !standardized.hasPrefix(homeDir + "/") {
            return false
        }
        
        for prefix in whitelistedPrefixes {
            if standardized.hasPrefix(prefix + "/") {
                return true
            }
        }
        
        if standardized.hasPrefix("\(homeDir)/Library/") {
            return false
        }
        
        let relativePath = standardized.dropFirst(homeDir.count + 1)
        let topLevelSegment = relativePath.components(separatedBy: "/").first ?? ""
        if topLevelSegment.hasPrefix(".") {
            return false
        }
        
        return true
    }
    
    public func trashItem(at url: URL) throws {
        let path = url.standardizedFileURL.path
        guard isAllowed(path: path) else {
            throw CleanerError.pathOutsideWhitelist
        }
        
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            logAction("Trashed: \(path)")
        } catch {
            logAction("Failed to trash: \(path) - \(error.localizedDescription)")
            throw CleanerError.deletionFailed(error.localizedDescription)
        }
    }
    
    public func logAction(_ message: String) {
        let logDir = URL(fileURLWithPath: "\(homeDir)/Library/Application Support/Rebes")
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        
        let logFile = logDir.appendingPathComponent("actions.log")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logLine = "[\(timestamp)] \(message)\n"
        
        if let data = logLine.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFile.path) {
                if let fileHandle = try? FileHandle(forWritingTo: logFile) {
                    fileHandle.seekToEndOfFile()
                    fileHandle.write(data)
                    fileHandle.closeFile()
                }
            } else {
                try? data.write(to: logFile)
            }
        }
    }
    
    public func directorySize(url: URL) -> Int64 {
        var size: Int64 = 0
        if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let fileURL as URL in enumerator {
                if let attr = try? fileURL.resourceValues(forKeys: [.fileSizeKey]), let fileSize = attr.fileSize {
                    size += Int64(fileSize)
                }
            }
        }
        if size == 0, let attr = try? url.resourceValues(forKeys: [.fileSizeKey]), let fileSize = attr.fileSize {
            size = Int64(fileSize)
        }
        return size
    }
}
