import Foundation
import FinanceCore

/// Parses the `searchTransactions` tool call inside the Agent chat
/// contract's `search` reply — `AIAgentChatProtocol` hands it the raw
/// args object and the granted window.
///
/// The reply is parsed strictly: the tool name must be exactly
/// `searchTransactions`, the args object may only contain the documented
/// keys, day filters must be `yyyy-MM-dd` days inside the grant, and
/// every bound is validated before any ledger read runs. The `parseDay`/
/// `dayString`/`coveredDayBounds` helpers are also how the chat
/// protocol renders and bounds its own day fields.
enum AIAgentToolPlanner {

    /// The only tool the model may call.
    static let searchToolName = "searchTransactions"
    /// Max length of the `text` search arg the model may emit.
    static let maxQueryTextLength = 100

    // MARK: - Parsing

    /// The arg keys the parser accepts — anything else fails the call.
    private static let allowedArgKeys: Set<String> = [
        "from", "to", "kind", "source",
        "minAmount", "maxAmount", "needsReview", "text",
    ]

    /// Parses the model's reply into the typed lookup query. Throws
    /// `unsupportedTool` for a wrong/missing tool name, `malformedQuery`
    /// for structurally bad args, and `queryOutsideWindow` when the day
    /// range escapes the grant — all before the ledger is read.
    static func parse(
        _ text: String,
        grantedWindow: DateInterval,
        calendar: Calendar = AppCalendar.vietnam
    ) throws -> AIAgentLookupQuery {
        guard let data = AIJSON.firstValueData(in: text),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any]
        else { throw AIAgentError.unparseableModelReply }

        guard (dict["tool"] as? String) == searchToolName
        else { throw AIAgentError.unsupportedTool }

        var args: [String: Any] = [:]
        if let raw = dict["args"] ?? dict["arguments"] ?? dict["parameters"],
           !(raw is NSNull) {
            guard let dict = raw as? [String: Any] else {
                throw AIAgentError.malformedQuery
            }
            args = dict
        }
        for key in args.keys where !allowedArgKeys.contains(key) {
            throw AIAgentError.malformedQuery
        }

        let interval = try parseInterval(args, within: grantedWindow,
                                         calendar: calendar)
        let kind = try parseKind(args)
        let source = try parseSource(args)
        let (minAmount, maxAmount) = try parseAmounts(args)
        let needsReview = try parseFlag(args)
        let queryText = try parseText(args)

        return AIAgentLookupQuery(
            interval: interval,
            kind: kind,
            source: source,
            unclassifiedOnly: needsReview,
            text: queryText,
            minAmount: minAmount,
            maxAmount: maxAmount)
    }

    /// from/to → the half-open `DateInterval` — `to` is an inclusive day,
    /// so the interval ends at the next day start. A missing side stays
    /// open on the grant's bound; either way the result must sit inside
    /// the grant.
    private static func parseInterval(
        _ args: [String: Any],
        within window: DateInterval,
        calendar: Calendar
    ) throws -> DateInterval? {
        var fromDay: Date?
        var toDay: Date?
        if let raw = args["from"], !(raw is NSNull) {
            guard let text = raw as? String,
                  let day = parseDay(text, calendar: calendar)
            else { throw AIAgentError.malformedQuery }
            fromDay = day
        }
        if let raw = args["to"], !(raw is NSNull) {
            guard let text = raw as? String,
                  let day = parseDay(text, calendar: calendar)
            else { throw AIAgentError.malformedQuery }
            toDay = day
        }
        guard fromDay != nil || toDay != nil else { return nil }
        if let fromDay, let toDay, toDay < fromDay {
            throw AIAgentError.malformedQuery
        }
        let start = fromDay ?? window.start
        let end: Date
        if let toDay {
            guard let next = calendar.date(
                byAdding: .day, value: 1, to: toDay)
            else { throw AIAgentError.malformedQuery }
            end = next
        } else {
            end = window.end
        }
        // A "from" past the grant's end would trap DateInterval's
        // start<=end precondition — containment is checked next anyway.
        guard start <= end else { throw AIAgentError.queryOutsideWindow }
        let interval = DateInterval(start: start, end: end)
        guard interval.start >= window.start, interval.end <= window.end
        else { throw AIAgentError.queryOutsideWindow }
        return interval
    }

    private static func parseKind(
        _ args: [String: Any]
    ) throws -> TransactionKind? {
        guard let raw = args["kind"], !(raw is NSNull) else { return nil }
        guard let text = raw as? String else {
            throw AIAgentError.malformedQuery
        }
        switch text.lowercased() {
        case "expense", "chi": return .expense
        case "income", "thu": return .income
        case "transfer", "chuyenkhoan", "chuyển khoản": return .transfer
        default: throw AIAgentError.malformedQuery
        }
    }

    private static func parseSource(
        _ args: [String: Any]
    ) throws -> AIAgentSource? {
        guard let raw = args["source"], !(raw is NSNull) else { return nil }
        guard let text = raw as? String else {
            throw AIAgentError.malformedQuery
        }
        switch text.lowercased() {
        case "manual": return .manual
        case "wallet": return .wallet
        case "csv": return .csv
        case "imported", "other", "otherimported": return .otherImported
        default: throw AIAgentError.malformedQuery
        }
    }

    /// min/max bounds in đồng — JSON numbers or amount strings via
    /// `AIAmountParser`, never booleans; both ≥ 0 and min ≤ max.
    private static func parseAmounts(
        _ args: [String: Any]
    ) throws -> (min: Int64?, max: Int64?) {
        func parse(_ key: String) throws -> Int64? {
            guard let raw = args[key], !(raw is NSNull) else { return nil }
            guard !(raw is Bool), let amount = AIAmountParser.parse(raw),
                  amount >= 0
            else { throw AIAgentError.malformedQuery }
            return amount
        }
        let min = try parse("minAmount")
        let max = try parse("maxAmount")
        if let min, let max, min > max {
            throw AIAgentError.malformedQuery
        }
        return (min, max)
    }

    private static func parseFlag(_ args: [String: Any]) throws -> Bool {
        guard let raw = args["needsReview"], !(raw is NSNull) else {
            return false
        }
        guard let flag = raw as? Bool else {
            throw AIAgentError.malformedQuery
        }
        return flag
    }

    private static func parseText(_ args: [String: Any]) throws -> String {
        guard let raw = args["text"], !(raw is NSNull) else { return "" }
        guard let text = raw as? String,
              text.count <= maxQueryTextLength
        else { throw AIAgentError.malformedQuery }
        return text
    }

    /// Strict `yyyy-MM-dd` in the Vietnam calendar — the only date shape
    /// the tool accepts.
    static func parseDay(_ text: String, calendar: Calendar) -> Date? {
        guard text.range(
            of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression
        ) != nil else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter.date(from: text)
    }

    static func dayString(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// The day range fully covered by a possibly ragged `window`: the
    /// model's filters are whole days, so the presented bounds are the
    /// days a filter may name without escaping the grant.
    static func coveredDayBounds(
        of window: DateInterval, calendar: Calendar
    ) -> (from: Date, to: Date) {
        var start = calendar.startOfDay(for: window.start)
        if start < window.start {
            start = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        }
        let endDay = calendar.startOfDay(for: window.end)
        let last = calendar.date(byAdding: .day, value: -1, to: endDay) ?? endDay
        return (start, last)
    }
}

