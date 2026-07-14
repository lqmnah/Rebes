//
//  LeftoverMatcher.swift
//  RebesCore
//
//  Single shared implementation of uninstaller leftover matching,
//  used by both the app and the self-test.
//

import Foundation

public enum LeftoverMatchKind: Equatable, Sendable {
    /// Item name contains the app's bundle identifier — safe to pre-select.
    case bundleId
    /// Item name equals the app name (ignoring a trailing extension) — safe to pre-select.
    case exactName
    /// Item name merely contains the app name — shown but NOT pre-selected,
    /// because it can belong to another app ("Notion" vs "Notion Calendar").
    case nameSubstring
    case none

    public var isMatch: Bool { self != .none }
    /// Only unambiguous matches may default to selected-for-deletion.
    public var preselect: Bool { self == .bundleId || self == .exactName }
}

public func leftoverMatch(itemName: String, appName: String, appBundleId: String) -> LeftoverMatchKind {
    if !appBundleId.isEmpty, itemName.localizedCaseInsensitiveContains(appBundleId) {
        return .bundleId
    }
    let base = (itemName as NSString).deletingPathExtension
    if base.compare(appName, options: .caseInsensitive) == .orderedSame ||
       itemName.compare(appName, options: .caseInsensitive) == .orderedSame {
        return .exactName
    }
    if appName.count >= 5, itemName.localizedCaseInsensitiveContains(appName) {
        return .nameSubstring
    }
    return .none
}
