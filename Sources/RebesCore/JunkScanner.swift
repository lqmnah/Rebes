import Foundation
import AppKit

public struct JunkCategory: Identifiable {
    public let id = UUID()
    public let name: String
    public let paths: [String]
    public var size: Int64 = 0
    public var items: [URL] = []
    public var isSelected: Bool = true
    public var isDisplayOnly: Bool = false
}

extension SafeCleaner {
    public func scanJunk() -> [JunkCategory] {
        var categories = [
            JunkCategory(name: "User Caches", paths: ["\(homeDir)/Library/Caches"]),
            JunkCategory(name: "System Logs", paths: ["\(homeDir)/Library/Logs"]),
            JunkCategory(name: "Xcode DerivedData", paths: ["\(homeDir)/Library/Developer/Xcode/DerivedData"]),
            JunkCategory(name: "NPM Cache", paths: ["\(homeDir)/.npm/_cacache"]),
            JunkCategory(name: "Homebrew Cache", paths: ["\(homeDir)/Library/Caches/Homebrew"]),
            JunkCategory(name: "Generic .cache", paths: ["\(homeDir)/.cache"]),
            JunkCategory(name: "PIP Cache", paths: ["\(homeDir)/Library/Caches/pip"]),
            JunkCategory(name: "Bun Cache", paths: ["\(homeDir)/.bun/install/cache"])
        ]
        
        // Paths that are their own category must not double-appear as items
        // of a parent category (e.g. ~/Library/Caches/Homebrew inside "User Caches") —
        // otherwise deselecting the child category would not actually protect it.
        let dedicatedPaths = Set(categories.flatMap { $0.paths }.map { URL(fileURLWithPath: $0).standardizedFileURL.path })

        for i in 0..<categories.count {
            var totalSize: Int64 = 0
            var urls: [URL] = []

            for path in categories[i].paths {
                let url = URL(fileURLWithPath: path)
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                    do {
                        let contents = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
                        for item in contents {
                            let itemPath = item.standardizedFileURL.path
                            if itemPath != URL(fileURLWithPath: path).standardizedFileURL.path,
                               dedicatedPaths.contains(itemPath) {
                                continue
                            }
                            urls.append(item)
                            totalSize += SafeCleaner.shared.directorySize(url: item)
                        }
                    } catch {
                    }
                }
            }
            categories[i].size = totalSize
            categories[i].items = urls
        }
        
        var trashSize: Int64 = 0
        let trashUrl = URL(fileURLWithPath: "\(homeDir)/.Trash")
        if let contents = try? FileManager.default.contentsOfDirectory(at: trashUrl, includingPropertiesForKeys: nil) {
            for item in contents {
                trashSize += SafeCleaner.shared.directorySize(url: item)
            }
        }
        categories.append(JunkCategory(name: "Trash (Display Only)", paths: [], size: trashSize, items: [], isSelected: false, isDisplayOnly: true))
        
        return categories
    }
    
}
