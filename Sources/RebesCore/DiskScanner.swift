//
//  DiskScanner.swift
//  RebesCore
//
//  Space Lens (folder size map) and Duplicate Finder.
//

import Foundation
import CryptoKit

public struct DiskEntry: Identifiable, Sendable {
    public let id = UUID()
    public let url: URL
    public let size: Int64
    public let isDirectory: Bool
    public let childCount: Int
}

public struct DuplicateGroup: Identifiable, Sendable {
    public let id = UUID()
    public let sizeEach: Int64
    public let urls: [URL]
    public init(sizeEach: Int64, urls: [URL]) {
        self.sizeEach = sizeEach
        self.urls = urls
    }
    /// Space reclaimable by keeping one copy.
    public var reclaimable: Int64 { sizeEach * Int64(max(0, urls.count - 1)) }
}

public enum DiskScanner {

    /// One level of a folder, each child with its recursive size, largest first.
    public static func spaceLens(at folder: URL) -> [DiskEntry] {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        var entries: [DiskEntry] = []
        for child in children {
            let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let size = SafeCleaner.shared.directorySize(url: child)
            var count = 0
            if isDir {
                count = (try? fm.contentsOfDirectory(atPath: child.path).count) ?? 0
            }
            entries.append(DiskEntry(url: child, size: size, isDirectory: isDir, childCount: count))
        }
        return entries.sorted { $0.size > $1.size }
    }

    /// Find duplicate files under `folder`. Two-stage: group by size, then hash
    /// only same-size candidates (hashing every file would be far slower).
    /// `minSize` skips trivially small files. Progress is reported per hashed file.
    public static func findDuplicates(
        in folder: URL,
        minSize: Int64 = 1_000_000,
        shouldCancel: () -> Bool = { false },
        progress: (String) -> Void = { _ in }
    ) -> [DuplicateGroup] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return []
        }

        // Don't offer files inside the Trash, caches, or app bundles as
        // "duplicates" — deleting one of those is not what the user means.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let skipFragments = ["/.Trash/", "/Library/Caches/", "/Library/Containers/", "\(home)/Library/"]
        func skip(_ url: URL) -> Bool {
            let p = url.path
            if p.contains(".app/") || p.contains(".framework/") || p.contains(".photoslibrary/") { return true }
            return skipFragments.contains { p.contains($0) }
        }

        // Stage 1: bucket regular files by size.
        var bySize: [Int64: [URL]] = [:]
        for case let url as URL in enumerator {
            if shouldCancel() { return [] }
            if skip(url) { continue }
            guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  v.isRegularFile == true, let s = v.fileSize, Int64(s) >= minSize else { continue }
            bySize[Int64(s), default: []].append(url)
        }

        // Stage 2: hash only sizes with >1 candidate.
        var groups: [DuplicateGroup] = []
        for (size, urls) in bySize where urls.count > 1 {
            if shouldCancel() { return groups }
            var byHash: [String: [URL]] = [:]
            for url in urls {
                if shouldCancel() { return groups }
                progress(url.lastPathComponent)
                guard let h = sha256(of: url) else { continue }
                byHash[h, default: []].append(url)
            }
            for (_, dupes) in byHash where dupes.count > 1 {
                groups.append(DuplicateGroup(sizeEach: size, urls: dupes))
            }
        }
        return groups.sorted { $0.reclaimable > $1.reclaimable }
    }

    /// Streaming SHA-256 so large files don't load fully into memory.
    /// Returns nil on ANY read error — a partial/failed read must never be
    /// treated as a complete hash, or two different files could be reported
    /// as duplicates and the wrong one deleted.
    private static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: 1 << 20)
            } catch {
                return nil   // read error → no hash, never a false match
            }
            guard let chunk, !chunk.isEmpty else { break }   // clean EOF
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
