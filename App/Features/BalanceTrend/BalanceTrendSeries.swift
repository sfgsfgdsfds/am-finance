import Foundation
import FinanceCore

/// The time spans offered by the range picker on the balance-history screen.
enum BalanceTrendRange: String, CaseIterable, Identifiable, Sendable {
    case days30
    case days90
    case year
    case all

    var id: String { rawValue }

    /// Vietnamese label for the segmented picker.
    var displayName: String {
        switch self {
        case .days30: return "30 ngày"
        case .days90: return "90 ngày"
        case .year: return "1 năm"
        case .all: return "Tất cả"
        }
    }

    /// First instant of the range. `.all` starts at the earliest known entry
    /// (clamped to `now` for ledgers that only hold future-dated rows, and to
    /// `now` itself when there are no entries at all).
    func start(now: Date, earliestEntry: Date?, calendar: Calendar) -> Date {
        switch self {
        case .days30:
            return calendar.date(byAdding: .day, value: -30, to: now) ?? now
        case .days90:
            return calendar.date(byAdding: .day, value: -90, to: now) ?? now
        case .year:
            return calendar.date(byAdding: .year, value: -1, to: now) ?? now
        case .all:
            return min(earliestEntry ?? now, now)
        }
    }
}

/// Everything `BalanceTrendView` renders, computed in one pure builder over
/// `BalanceHistory`: the daily closing balances, the downsampled chart
/// points and the summary card. All inputs are plain values — signed opening
/// balance, lightweight signed entries, the range, `now`, the liability flag
/// and the calendar — so the whole screen is testable without SwiftUI or
/// SwiftData.
///
/// Display convention: balances are rendered in "displayed" terms — a
/// liability's debt is shown as a positive number ("Dư nợ"), so every balance
/// figure here is already sign-flipped. Flows (`totalIn`, `totalOut`,
/// `netChange`) keep their ledger sign: positive is money into the account.
struct BalanceTrendSeries: Equatable {

    /// Upper bound of points sent to the chart (spec: at most 120).
    static let maxChartPoints = 120

    let range: BalanceTrendRange
    /// Start of the first day in the range, in `calendar`.
    let start: Date
    /// The instant the range ends — always `now` as passed to `build`.
    let end: Date
    let isLiability: Bool

    /// Closing balance for every calendar day in the range, displayed terms.
    let dailyPoints: [BalanceHistoryPoint]
    /// `dailyPoints` thinned to at most `maxChartPoints` for rendering.
    let chartPoints: [BalanceHistoryPoint]

    // Summary card (balances in displayed terms).
    /// Balance carried into the range — close of the day before `start`.
    let opening: Int64
    /// Balance after the last entry in the range.
    let closing: Int64
    /// Sum of positive deltas in the range (money into the account).
    let totalIn: Int64
    /// Sum of negative deltas in the range, positive magnitude.
    let totalOut: Int64
    /// `totalIn - totalOut` — signed in ledger terms for both kinds.
    let netChange: Int64
    /// Lowest displayed balance and its date (smallest debt on liabilities).
    let lowest: BalanceHistoryPoint
    /// Highest displayed balance and its date (largest debt on liabilities).
    let highest: BalanceHistoryPoint

    /// Signed ledger balance → displayed figure: liabilities show the debt
    /// as a positive number. `Int64.min` saturates instead of trapping.
    static func displayed(_ signed: Int64, isLiability: Bool) -> Int64 {
        guard isLiability else { return signed }
        return signed == .min ? .max : -signed
    }

    /// Builds the series. `start` is snapped to the start of its day so the
    /// summary's "opening" is a true end-of-previous-day figure and the first
    /// chart day covers the whole day.
    static func build(
        entries: [BalanceHistoryEntry],
        openingBalance: Int64,
        range: BalanceTrendRange,
        now: Date,
        isLiability: Bool,
        calendar: Calendar = AppCalendar.vietnam
    ) throws -> BalanceTrendSeries {
        let earliest = entries.map(\.date).min()
        let rawStart = range.start(now: now, earliestEntry: earliest, calendar: calendar)
        let start = min(
            calendar.startOfDay(for: rawStart),
            calendar.startOfDay(for: now)
        )

        let daily = try BalanceHistory.dailyBalances(
            entries: entries,
            from: start,
            to: now,
            basis: .opening(openingBalance),
            calendar: calendar
        )
        let summary = try BalanceHistory.summary(
            entries: entries,
            from: start,
            to: now,
            basis: .opening(openingBalance)
        )

        let shownDaily = daily.map {
            BalanceHistoryPoint(
                date: $0.date,
                balance: displayed($0.balance, isLiability: isLiability)
            )
        }
        // The signed minimum is a liability's largest displayed debt, and
        // vice versa — swap the extremes when flipping the sign.
        let lowest = isLiability
            ? BalanceHistoryPoint(
                date: summary.maximum.date,
                balance: displayed(summary.maximum.balance, isLiability: true))
            : summary.minimum
        let highest = isLiability
            ? BalanceHistoryPoint(
                date: summary.minimum.date,
                balance: displayed(summary.minimum.balance, isLiability: true))
            : summary.maximum

        return BalanceTrendSeries(
            range: range,
            start: start,
            end: now,
            isLiability: isLiability,
            dailyPoints: shownDaily,
            chartPoints: BalanceHistory.downsample(shownDaily, maxCount: maxChartPoints),
            opening: displayed(summary.opening, isLiability: isLiability),
            closing: displayed(summary.closing, isLiability: isLiability),
            totalIn: summary.totalIn,
            totalOut: summary.totalOut,
            netChange: summary.netChange,
            lowest: lowest,
            highest: highest
        )
    }
}

extension Account {
    /// The account's movements as `BalanceHistory` entries: the signed delta
    /// of every transaction it participates in — source role via
    /// `LedgerMath.delta`, transfer destination `+amount` — de-duplicated by
    /// transaction id and sorted stably by date (relationship arrays have no
    /// guaranteed order).
    var balanceTrendEntries: [BalanceHistoryEntry] {
        var seen = Set<UUID>()
        var entries: [BalanceHistoryEntry] = []
        for transaction in (transactions ?? []) + (incomingTransfers ?? []) {
            guard seen.insert(transaction.id).inserted else { continue }
            let role: LedgerMath.Role = transaction.account === self ? .source : .destination
            let delta = LedgerMath.delta(
                kind: transaction.kind, amount: transaction.amount, role: role
            )
            if delta != 0 {
                entries.append(BalanceHistoryEntry(date: transaction.date, delta: delta))
            }
        }
        return entries
            .enumerated()
            .sorted { lhs, rhs in
                lhs.element.date == rhs.element.date
                    ? lhs.offset < rhs.offset
                    : lhs.element.date < rhs.element.date
            }
            .map(\.element)
    }
}
