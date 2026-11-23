import Foundation
import FinanceCore

/// Stage 1 of the agent pipeline: turns the user's bounded question into
/// one allow-listed `searchTransactions` tool call.
///
/// The request carries only the question text, "today" and the granted
/// date range as Vietnamese-local days — never ledger rows, category
/// catalogs or conversation history. The reply is parsed strictly: the
/// tool name must be exactly `searchTransactions`, the args object may
/// only contain the documented keys, day filters must be `yyyy-MM-dd`
/// days inside the grant, and every bound is validated before any ledger
/// read runs.
enum AIAgentToolPlanner {

    /// The only tool the model may call.
    static let searchToolName = "searchTransactions"
    /// Characters of user question actually sent — excess is cut.
    static let maxQuestionLength = 1_000
    /// Max length of the `text` search arg the model may emit.
    static let maxQueryTextLength = 100

    /// The stage-1 request: analyst-agnostic, JSON-mode, exactly one user
    /// message holding the bounded question.
    static func request(
        question: String,
        permission: AIAgentPermission,
        now: Date,
        calendar: Calendar = AppCalendar.vietnam
    ) -> AIRequest {
        AIRequest(
            system: systemPrompt(
                window: permission.window, now: now, calendar: calendar),
            messages: [AIMessage(role: .user, text: bounded(question))],
            jsonMode: true)
    }

    /// The question trimmed and cut to `maxQuestionLength`.
    static func bounded(_ question: String) -> String {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(maxQuestionLength))
    }

    /// The Vietnamese system prompt — auditable by the owner. It states
    /// "today", the allowed day range in ISO form, the one tool and its
    /// exact JSON shape; nothing else is needed since no data rides in.
    static func systemPrompt(
        window: DateInterval,
        now: Date,
        calendar: Calendar = AppCalendar.vietnam
    ) -> String {
        let covered = coveredDayBounds(of: window, calendar: calendar)
        var parts: [String] = []
        parts.append(
            "Bạn là bộ lọc tìm kiếm của ứng dụng quản lý tài chính AM Finance. "
                + "Nhiệm vụ DUY NHẤT: chuyển câu hỏi của người dùng thành MỘT lời gọi công cụ "
                + "\"\(searchToolName)\". Không trả lời nội dung câu hỏi, không gọi công cụ "
                + "nào khác, không tự tạo dữ liệu.")
        let day = AppDateFormat.shortDate(now, calendar: calendar)
        let weekday = calendar.component(.weekday, from: now)
        parts.append(
            "Hôm nay là \(weekday == 1 ? "Chủ nhật" : "thứ \(weekday)"), \(day), "
                + "múi giờ Asia/Ho_Chi_Minh (UTC+7). Quy mọi ngày tương đối (hôm nay, "
                + "hôm qua, tuần trước, tháng này…) về ngày tuyệt đối theo múi giờ này.")
        parts.append(
            "Khoảng ngày được phép: từ \(dayString(covered.from, calendar: calendar)) "
                + "đến hết \(dayString(covered.to, calendar: calendar)) — mọi bộ lọc ngày "
                + "phải nằm trọn trong khoảng này.")
        parts.append(
            """
            Chỉ trả lời bằng JSON đúng dạng sau, không thêm lời nào khác:
            {"tool":"\(searchToolName)","args":{"from":"yyyy-MM-dd","to":"yyyy-MM-dd","kind":"expense","source":"manual","minAmount":0,"maxAmount":0,"needsReview":false,"text":"..."}}
            - from/to: ngày tuyệt đối yyyy-MM-dd; "to" tính cả ngày đó. Bỏ qua = lọc trên cả khoảng được phép.
            - kind: "expense" (chi), "income" (thu) hoặc "transfer" (chuyển khoản).
            - source: "manual" (nhập tay), "wallet" (đồng bộ ví), "csv" (nhập CSV) hoặc "imported" (nguồn khác).
            - minAmount/maxAmount: đồng, số nguyên ≥ 0, min ≤ max.
            - needsReview: true = chỉ giao dịch chưa phân loại hoặc chờ duyệt.
            - text: từ khoá ngắn tìm trong ghi chú/tên danh mục/tài khoản.
            Mọi trường trong args đều tuỳ chọn — chỉ điền trường câu hỏi yêu cầu. Không thêm trường khác.
            """)
        return parts.joined(separator: "\n")
    }

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

/// Stage 2: builds the fixed analysis request from the prepared preview
/// and parses the reply into a Vietnamese answer plus validated
/// `setCategory` proposals.
///
/// The outgoing payload is the privacy projection itself: ephemeral
/// `R…`/`C…` handles, positive đồng magnitudes, `yyyy-MM-dd` days,
/// category names and provenance buckets — no SwiftData ids, external
/// ids, balances or keys. Model output is untrusted: the parser maps
/// handles back through the prepared tables and any single violation
/// voids the whole proposal list while keeping the answer.
enum AIAgentAnalysisPlanner {

    /// Proposals the model may emit — the result cap means there is
    /// never a legitimate need for more than one per surfaced row.
    static let maxProposals = AIAgentLedgerTools.resultLimit

    /// The stage-2 request: the analyst system prompt plus one user
    /// message containing the exact JSON projection of the preview.
    static func request(
        preview: AIAgentDataPreview,
        categories: [AIAgentCategoryHandle],
        grantsProposals: Bool,
        calendar: Calendar = AppCalendar.vietnam
    ) -> AIRequest {
        AIRequest(
            system: systemPrompt(grantsProposals: grantsProposals),
            messages: [AIMessage(
                role: .user,
                text: payloadText(
                    preview: preview, categories: categories,
                    grantsProposals: grantsProposals, calendar: calendar))],
            jsonMode: true)
    }

    static func systemPrompt(grantsProposals: Bool) -> String {
        var parts: [String] = []
        parts.append(
            "Bạn là trợ lý phân tích của ứng dụng quản lý tài chính AM Finance, "
                + "luôn trả lời bằng tiếng Việt.")
        parts.append(
            "Payload JSON gồm câu hỏi \"question\", khoảng ngày \"window\" và tối đa "
                + "\(AIAgentLedgerTools.resultLimit) giao dịch trong \"rows\" — id R1, R2… "
                + "là handle tạm, không phải id thật. \"amount\" là đồng, số dương; "
                + "\"kind\" = expense|income|transfer; \"canEdit\" = đổi được danh mục.")
        parts.append(
            """
            Quy tắc:
            - Chỉ lập luận trên các dòng được cung cấp — không bịa số liệu; khi "truncated": true, nói rõ kết quả có thể chưa đầy đủ.
            - Viết số tiền kiểu 1.250.000 ₫; trả lời NGẮN, đi thẳng vào câu hỏi.
            - Chỉ trả lời bằng JSON: {"answer":"...","proposals":[...]}
            """)
        if grantsProposals {
            parts.append(
                "- Nếu câu hỏi xin đổi danh mục các giao dịch, bạn được đề xuất mỗi dòng "
                    + "TỐI ĐA một lệnh {\"action\":\"setCategory\",\"row\":\"R3\",\"category\":\"C5\"} "
                    + "trong \"proposals\" — chỉ dùng handle R…/C… có trong payload, chỉ với dòng "
                    + "\"canEdit\": true, danh mục đúng chiều (expense → danh mục expense, "
                    + "income → danh mục income), và không chọn lại danh mục hiện tại của "
                    + "dòng. Không chắc thì để proposals rỗng.")
        } else {
            parts.append("- \"proposals\" luôn là [].")
        }
        return parts.joined(separator: "\n")
    }

    // MARK: - Outgoing payload

    /// The exact JSON body the provider receives — deterministic keys,
    /// handles only. `categories` is present solely when the grant
    /// allows proposals; row notes/account names appear solely when the
    /// caller opted them into the preview.
    static func payloadText(
        preview: AIAgentDataPreview,
        categories: [AIAgentCategoryHandle],
        grantsProposals: Bool,
        calendar: Calendar
    ) -> String {
        var payload: [String: Any] = [
            "question": preview.question,
            "window": [
                "from": AIAgentToolPlanner.dayString(
                    preview.window.start, calendar: calendar),
                "to": AIAgentToolPlanner.dayString(
                    preview.window.end.addingTimeInterval(-1),
                    calendar: calendar),
            ],
            "scanned": preview.scanned,
            "truncated": preview.truncated,
        ]
        payload["rows"] = preview.rows.map { row -> [String: Any] in
            var item: [String: Any] = [
                "id": row.handle,
                "kind": row.kind.rawValue,
                "amount": row.amount,
                "date": AIAgentToolPlanner.dayString(
                    row.date, calendar: calendar),
                "source": row.source.rawValue,
                "needsReview": row.needsReview,
                "canEdit": row.editable,
            ]
            item["category"] = row.categoryName.map { $0 as Any } ?? NSNull()
            if let note = row.note { item["note"] = note }
            if let account = row.accountName { item["account"] = account }
            return item
        }
        if grantsProposals {
            payload["categories"] = [
                "expense": categories.filter { $0.kind == .expense }
                    .map { ["id": $0.handle, "name": $0.name] },
                "income": categories.filter { $0.kind == .income }
                    .map { ["id": $0.handle, "name": $0.name] },
            ]
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.sortedKeys])
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Reply parsing

    /// Parses the analysis reply. The JSON object must carry a string
    /// `answer` (empty when absent); `proposals` — when present — is a
    /// strict list of `{"action":"setCategory","row":"R#","category":"C#"}`.
    /// One bad proposal voids them all: the returned analysis keeps the
    /// answer and reports the first failure in `proposalRejection`.
    /// `canPropose` is the *current* grant re-checked by the caller —
    /// proposals arriving without it are refused wholesale.
    static func parse(
        _ text: String,
        prepared: AIAgentPreparedAnalysis,
        canPropose: Bool
    ) throws -> AIAgentAnalysis {
        var analysis = AIAgentAnalysis(
            answer: "", proposals: [], proposalRejection: nil,
            effectiveWindow: prepared.effectiveWindow)

        guard let data = AIJSON.firstValueData(in: text),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any]
        else { throw AIAgentError.unparseableModelReply }

        if let raw = dict["answer"], !(raw is NSNull) {
            guard let answer = raw as? String else {
                throw AIAgentError.unparseableModelReply
            }
            analysis.answer = answer
        }

        let rawProposals: [Any]
        if let raw = dict["proposals"] ?? dict["edits"] ?? dict["actions"],
           !(raw is NSNull) {
            guard let list = raw as? [Any] else {
                analysis.proposalRejection = .invalidProposal
                return analysis
            }
            rawProposals = list
        } else {
            rawProposals = []
        }

        guard !rawProposals.isEmpty else { return analysis }
        guard canPropose else {
            analysis.proposalRejection = .permissionDenied
            return analysis
        }
        guard rawProposals.count <= maxProposals else {
            analysis.proposalRejection = .tooManyProposals
            return analysis
        }

        var proposals: [AIAgentCategoryProposal] = []
        proposals.reserveCapacity(rawProposals.count)
        var seen = Set<String>()
        do {
            for item in rawProposals {
                proposals.append(try proposal(
                    from: item, prepared: prepared, seen: &seen))
            }
        } catch let error as AIAgentError {
            analysis.proposalRejection = error
            return analysis
        }
        analysis.proposals = proposals
        return analysis
    }

    /// Validates one raw proposal dict against the prepared handle
    /// tables — every check the task requires, in one place.
    private static func proposal(
        from item: Any,
        prepared: AIAgentPreparedAnalysis,
        seen: inout Set<String>
    ) throws -> AIAgentCategoryProposal {
        guard let dict = item as? [String: Any],
              let action = dict["action"] as? String
        else { throw AIAgentError.invalidProposal }
        guard action == "setCategory"
        else { throw AIAgentError.unsupportedTool }
        guard let rowHandle = dict["row"] as? String,
              let categoryHandle = dict["category"] as? String
        else { throw AIAgentError.invalidProposal }
        guard seen.insert(rowHandle).inserted
        else { throw AIAgentError.duplicateTransaction }
        guard let match = prepared.matches[rowHandle],
              let row = prepared.preview.rows.first(
                  where: { $0.handle == rowHandle }),
              let category = prepared.categories.first(
                  where: { $0.handle == categoryHandle })
        else { throw AIAgentError.unknownHandle }

        let snapshot = match.original
        // The same eligibility rule the apply enforces, read from the
        // snapshot — transfers and rental-linked rows are out of scope.
        guard AIAgentLedgerTools.canEditCategory(of: snapshot)
        else { throw AIAgentError.transactionNotEligible }
        guard category.kind == AIAgentLedgerTools.categoryKind(of: snapshot.kind)
        else { throw AIAgentError.invalidCategory }
        // A clean same-category re-pick changes nothing — a no-op.
        guard !(snapshot.categoryID == category.id && !snapshot.needsReview)
        else { throw AIAgentError.noOpEdit }
        return AIAgentCategoryProposal(
            row: row, match: match, category: category)
    }
}
