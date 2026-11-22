import Foundation
import FinanceCore

/// Which grouping a spending-share donut shows: per category ("Danh mục")
/// or per money area ("Mảng") — personal spending vs each business.
enum SpendingShareMode: String, CaseIterable, Sendable {
    case category
    case segment

    /// Vietnamese label for the segmented switch.
    var displayName: String {
        switch self {
        case .category: return "Danh mục"
        case .segment: return "Mảng"
        }
    }
}

/// Name/icon/color styling of one category or business, looked up by id —
/// keeps `SpendingShareBuilder` free of SwiftData models.
struct SpendingShareEntityInfo: Equatable, Sendable {
    var name: String
    var icon: String
    var colorHex: String

    init(name: String, icon: String = "", colorHex: String = "") {
        self.name = name
        self.icon = icon
        self.colorHex = colorHex
    }
}

/// One computed donut slice with the routing ids a host needs for
/// drill-down (`categoryID` / `businessID` / `isPersonal`).
struct SpendingShareSlice: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var amount: Int64
    var colorHex: String
    /// Whole percent of the total; all slice percents sum to exactly 100.
    var percent: Int
    /// Set in `.category` mode — nil means "Chưa phân loại".
    var categoryID: UUID?
    /// Set in `.segment` mode — nil only on the "Cá nhân" slice.
    var businessID: UUID?
    /// The folded "Khác" slice — no drill-down.
    var isOther: Bool
    /// The "Cá nhân" segment slice (entries without a business).
    var isPersonal: Bool

    init(
        id: String, name: String, amount: Int64, colorHex: String,
        percent: Int = 0, categoryID: UUID? = nil, businessID: UUID? = nil,
        isOther: Bool = false, isPersonal: Bool = false
    ) {
        self.id = id
        self.name = name
        self.amount = amount
        self.colorHex = colorHex
        self.percent = percent
        self.categoryID = categoryID
        self.businessID = businessID
        self.isOther = isOther
        self.isPersonal = isPersonal
    }
}

/// The builder's output: the folded slice list plus the grand total.
struct SpendingShareResult: Equatable, Sendable {
    var slices: [SpendingShareSlice]
    var total: Int64

    var isEmpty: Bool { slices.isEmpty }

    init(slices: [SpendingShareSlice] = [], total: Int64 = 0) {
        self.slices = slices
        self.total = total
    }
}

/// Spending-share aggregation over lightweight `ReportEntry` values: one
/// date interval, one kind (expense or income — transfers never match) and
/// one mode. Pure value math, so callers can run it off the main actor.
enum SpendingShareBuilder {

    /// Identity of the "Cá nhân" segment slice.
    static let personalID = "personal"
    /// "Cá nhân" display color — indigo, distinct from the gray reserved
    /// for "Chưa phân loại" / "Khác".
    static let personalColorHex = "5E5CE6"

    /// Everything `compute` reads — plain Sendable values so the view can
    /// build it on the main actor and hand it to a detached task.
    struct Input: Sendable {
        var entries: [ReportEntry]
        var interval: ReportDateInterval
        var kind: TransactionKind
        var mode: SpendingShareMode
        var scope: ReportScope
        var categories: [UUID: SpendingShareEntityInfo]
        var businesses: [UUID: SpendingShareEntityInfo]
        /// Slices kept before folding into "Khác".
        var limit: Int

        init(
            entries: [ReportEntry],
            interval: ReportDateInterval,
            kind: TransactionKind,
            mode: SpendingShareMode,
            scope: ReportScope = .all,
            categories: [UUID: SpendingShareEntityInfo] = [:],
            businesses: [UUID: SpendingShareEntityInfo] = [:],
            limit: Int = ShareDonutMath.sliceLimit
        ) {
            self.entries = entries
            self.interval = interval
            self.kind = kind
            self.mode = mode
            self.scope = scope
            self.categories = categories
            self.businesses = businesses
            self.limit = limit
        }

        /// A stable hash of everything `compute` reads — feeds `.task(id:)`
        /// so the view recomputes exactly when an input changes.
        var fingerprint: Int {
            var hasher = Hasher()
            hasher.combine(interval.start)
            hasher.combine(interval.end)
            hasher.combine(kind.rawValue)
            hasher.combine(mode.rawValue)
            hasher.combine(limit)
            switch scope {
            case .all: hasher.combine(0)
            case .personal: hasher.combine(1)
            case .anyBusiness: hasher.combine(2)
            case .business(let id): hasher.combine(3); hasher.combine(id)
            }
            for entry in entries {
                hasher.combine(entry.date)
                hasher.combine(entry.kind.rawValue)
                hasher.combine(entry.amount)
                hasher.combine(entry.categoryID)
                hasher.combine(entry.businessID)
            }
            let sortedCategories = categories.sorted {
                $0.key.uuidString < $1.key.uuidString
            }
            for (id, info) in sortedCategories {
                hasher.combine(id)
                hasher.combine(info.name)
                hasher.combine(info.colorHex)
            }
            let sortedBusinesses = businesses.sorted {
                $0.key.uuidString < $1.key.uuidString
            }
            for (id, info) in sortedBusinesses {
                hasher.combine(id)
                hasher.combine(info.name)
                hasher.combine(info.colorHex)
            }
            return hasher.finalize()
        }
    }

    /// The share donut's slice list for `input`: totals grouped by category
    /// or by segment, sorted descending, folded at `input.limit` into a
    /// trailing "Khác" slice, with largest-remainder percents that sum to
    /// exactly 100. Empty result when nothing of `kind` is in range.
    static func compute(_ input: Input) -> SpendingShareResult {
        var total: Int64 = 0
        var grouped: [UUID?: Int64] = [:]
        for entry in input.entries
        where entry.kind == input.kind
            && input.interval.contains(entry.date)
            && matches(entry, scope: input.scope) {
            total = ShareDonutMath.saturatingAdd(total, entry.amount)
            let key = input.mode == .category
                ? entry.categoryID
                : entry.businessID
            grouped[key] = ShareDonutMath.saturatingAdd(
                grouped[key] ?? 0, entry.amount)
        }
        guard total > 0 else { return SpendingShareResult() }

        var slices = grouped.map { id, amount in
            input.mode == .category
                ? categorySlice(id: id, amount: amount, info: input.categories)
                : segmentSlice(id: id, amount: amount, info: input.businesses)
        }
        slices = folded(slices, limit: input.limit)
        let percents = ShareDonutMath.percents(
            amounts: slices.map(\.amount))
        for index in slices.indices {
            slices[index].percent = percents[index]
        }
        return SpendingShareResult(slices: slices, total: total)
    }

    // MARK: - Slices

    private static func categorySlice(
        id: UUID?, amount: Int64, info: [UUID: SpendingShareEntityInfo]
    ) -> SpendingShareSlice {
        let entity = id.flatMap { info[$0] }
        let known = entity.flatMap { $0.name.isEmpty ? nil : $0.name }
        return SpendingShareSlice(
            id: "category-\(id?.uuidString ?? "none")",
            name: known ?? "Chưa phân loại",
            amount: amount,
            colorHex: entity?.colorHex ?? ShareDonutMath.otherColorHex,
            categoryID: id
        )
    }

    private static func segmentSlice(
        id: UUID?, amount: Int64, info: [UUID: SpendingShareEntityInfo]
    ) -> SpendingShareSlice {
        guard let id else {
            return SpendingShareSlice(
                id: personalID,
                name: "Cá nhân",
                amount: amount,
                colorHex: personalColorHex,
                isPersonal: true
            )
        }
        let entity = info[id]
        let known = entity.flatMap { $0.name.isEmpty ? nil : $0.name }
        return SpendingShareSlice(
            id: "business-\(id.uuidString)",
            name: known ?? "Kinh doanh",
            amount: amount,
            colorHex: entity?.colorHex ?? ShareDonutMath.otherColorHex,
            businessID: id
        )
    }

    /// Same shape as `ShareDonutMath.folded` for the richer slice type —
    /// descending order, tail past `limit` summed into "Khác"; incoming
    /// `isOther` slices merge into the folded total.
    private static func folded(
        _ slices: [SpendingShareSlice], limit: Int
    ) -> [SpendingShareSlice] {
        var regulars: [SpendingShareSlice] = []
        var rest: Int64 = 0
        var hasOther = false
        for slice in slices {
            if slice.isOther {
                hasOther = true
                rest = ShareDonutMath.saturatingAdd(rest, slice.amount)
            } else {
                regulars.append(slice)
            }
        }
        let ordered = regulars.sorted { lhs, rhs in
            if lhs.amount != rhs.amount { return lhs.amount > rhs.amount }
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            return lhs.id < rhs.id
        }
        let kept = max(0, limit)
        guard ordered.count > kept || hasOther else { return ordered }
        for slice in ordered.dropFirst(kept) {
            rest = ShareDonutMath.saturatingAdd(rest, slice.amount)
        }
        return Array(ordered.prefix(kept)) + [
            SpendingShareSlice(
                id: ShareDonutMath.otherID,
                name: ShareDonutMath.otherName,
                amount: rest,
                colorHex: ShareDonutMath.otherColorHex,
                isOther: true
            )
        ]
    }

    private static func matches(_ entry: ReportEntry, scope: ReportScope) -> Bool {
        switch scope {
        case .all: return true
        case .personal: return entry.businessID == nil
        case .anyBusiness: return entry.businessID != nil
        case .business(let id): return entry.businessID == id
        }
    }
}
