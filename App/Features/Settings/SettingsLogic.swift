import Foundation

/// Case- and diacritic-insensitive folding for duplicate-name checks, so
/// "Ăn uống", "an uong" and " ĂN   UỐNG " are treated as the same name.
/// Vietnamese "đ" does not decompose in Unicode, so it is folded by hand.
enum SettingsNameNormalizer {
    static func fold(_ name: String) -> String {
        let folded = name
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "đ", with: "d")
        return folded
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// Drag-to-reorder helpers. `moved` mirrors the array change SwiftUI's
/// `onMove` performs; `renumber` then rewrites `sortOrder` to the new order.
enum SettingsReorder {
    static func moved<T>(_ items: [T], from source: IndexSet, to destination: Int) -> [T] {
        var copy = items
        copy.move(fromOffsets: source, toOffset: destination)
        return copy
    }

    /// Writes `sortOrder` = index for each element, in display order.
    /// Only meaningful for reference types (SwiftData models).
    static func renumber<T: AnyObject>(_ items: [T], sortOrder: ReferenceWritableKeyPath<T, Int>) {
        for (index, item) in items.enumerated() {
            item[keyPath: sortOrder] = index
        }
    }
}

/// Delete-versus-archive rule for managed rows (categories, businesses).
/// A row a transaction still references keeps history: it cannot be
/// deleted, only archived so it disappears from pickers.
enum SettingsDeleteRule {
    enum Decision: Equatable {
        /// Nothing references the row — it can be deleted outright.
        case delete
        /// In use — offer archive instead. Carries the reference count so
        /// the alert can explain why.
        case archiveOnly(transactionCount: Int)
    }

    static func decision(transactionCount: Int) -> Decision {
        transactionCount > 0
            ? .archiveOnly(transactionCount: transactionCount)
            : .delete
    }
}

/// Strings for the "Giới thiệu" section, read from the bundle. The pure
/// `versionText` keeps the formatting testable without a real Info.plist.
enum SettingsAbout {
    static var appName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "AM Finance"
    }

    static var versionText: String {
        versionText(
            shortVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
    }

    /// "1.0 (23)" — skips the build when it equals the version, falls back
    /// to "—" when both are missing (previews, test hosts).
    static func versionText(shortVersion: String?, build: String?) -> String {
        let version = shortVersion.flatMap { $0.isEmpty ? nil : $0 }
        let build = build.flatMap { $0.isEmpty ? nil : $0 }
        switch (version, build) {
        case let (version?, build?) where version != build:
            return "\(version) (\(build))"
        case let (version?, _):
            return version
        case let (nil, build?):
            return build
        case (nil, nil):
            return "—"
        }
    }
}
