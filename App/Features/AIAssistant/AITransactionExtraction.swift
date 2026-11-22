import Foundation
import FinanceCore

/// Case- and diacritic-insensitive name → id lookup. Vietnamese diacritics
/// are folded ("Ăn uống" matches "an uong", "đ" folds to "d"), whitespace is
/// collapsed, so model-returned names match the user's real data loosely.
struct AINameIndex: Sendable {
    private var table: [String: UUID] = [:]

    init(_ entries: [(id: UUID, name: String)]) {
        for entry in entries {
            let key = Self.normalized(entry.name)
            if !key.isEmpty { table[key] = entry.id }
        }
    }

    init(names: [UUID: String]) {
        self.init(names.map { (id: $0.key, name: $0.value) })
    }

    /// The id for `name`, or nil when unknown / blank.
    func match(_ name: String?) -> UUID? {
        guard let name else { return nil }
        return table[Self.normalized(name)]
    }

    static func normalized(_ name: String) -> String {
        var folded = name.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: Locale(identifier: "vi_VN")
        )
        folded = folded.replacingOccurrences(of: "đ", with: "d")
            .replacingOccurrences(of: "Đ", with: "D")
        return folded.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// Parses the amounts a model may emit: JSON numbers, grouped strings
/// ("85.000"), FinanceCore shorthand ("85k", "1,2tr") and spoken Vietnamese
/// forms it commonly produces ("1tr2" = 1.200.000, "2 củ" = 2.000.000,
/// "3 cành" = 3.000).
enum AIAmountParser {
    /// Slang that maps to a magnitude suffix once spaces are removed.
    /// Longest first so "lọng" beats nothing accidentally.
    private static let slang: [(String, String)] = [
        ("nghìn", "k"), ("ngàn", "k"), ("cành", "k"), ("lú", "k"),
        ("triệu", "tr"), ("củ", "tr"), ("lọng", "tr"), ("chai", "tr"),
        ("tỷ", "tỷ"), ("tỉ", "tỷ"), ("ty", "tỷ"),
    ]

    static func parse(_ value: Any) -> Int64? {
        if let int = value as? Int64 { return int }
        if let int = value as? Int { return Int64(int) }
        if let number = value as? NSNumber { return Int64(number.doubleValue.rounded()) }
        if let double = value as? Double { return Int64(double.rounded()) }
        guard let string = value as? String else { return nil }
        return parse(string)
    }

    static func parse(_ raw: String) -> Int64? {
        var s = raw.lowercased()
            .components(separatedBy: .whitespacesAndNewlines).joined()
        guard !s.isEmpty else { return nil }

        // Spoken slang suffixes → magnitude suffixes VND understands.
        for (word, suffix) in slang where s.hasSuffix(word) {
            s = s.dropLast(word.count) + suffix
            break
        }

        // "1tr2" / "2tỷ5" / "85k5" — digits after the magnitude are a
        // decimal fraction: "1tr2" → "1.2tr".
        let pattern = #"^([0-9]+(?:[.,][0-9]+)?)(tr|tỷ|ty|k|m)([0-9]+)$"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(
               in: s, range: NSRange(s.startIndex..., in: s)),
           let head = Range(match.range(at: 1), in: s),
           let magnitude = Range(match.range(at: 2), in: s),
           let fraction = Range(match.range(at: 3), in: s) {
            s = "\(s[head]).\(s[fraction])\(s[magnitude])"
        }

        return VND.parse(s)
    }
}

/// One validated draft produced by `AITransactionExtraction.parse` — every
/// field resolved against the app's real data; `warnings` explain any
/// fallbacks applied (unknown names, clamped dates).
struct AIDraftTransaction: Sendable, Equatable {
    var kind: TransactionKind
    var amount: Int64
    var date: Date
    var note: String
    var categoryID: UUID?
    var accountID: UUID?
    var toAccountID: UUID?
    var businessID: UUID?
    var confidence: Double
    var warnings: [String] = []
}

/// An item the model emitted that failed validation — kept so the screen
/// can say "1 dòng không đọc được".
struct AIExtractionRejection: Sendable, Equatable {
    var index: Int
    var reason: String
}

struct AIExtractionResult: Sendable, Equatable {
    var drafts: [AIDraftTransaction]
    var rejections: [AIExtractionRejection]
    /// The model's own note when nothing could be extracted (or a caveat).
    var message: String?
}

/// Builds the extraction system prompt (bill photo and/or typed sentence →
/// transactions) and parses the model's JSON reply into validated drafts.
enum AITransactionExtraction {

    /// The names the model may reference — supplied once for prompt building
    /// and again (with ids) for parsing.
    struct PromptInput: Sendable {
        var now: Date
        var expenseCategories: [String]
        var incomeCategories: [String]
        var accounts: [(name: String, kind: AccountKind)]
        var businesses: [String]
    }

    /// The strict-JSON instructions. Vietnamese so the owner can audit what
    /// is being asked; the JSON keys stay English for reliability.
    static func systemPrompt(
        for input: PromptInput,
        calendar: Calendar = AppCalendar.vietnam
    ) -> String {
        var parts: [String] = []
        parts.append(
            "Bạn là trợ lý nhập liệu của một ứng dụng quản lý tài chính cá nhân ở Việt Nam. "
                + "Nhiệm vụ: đọc ảnh hoá đơn/bill và/hoặc câu người dùng nhập, rồi trích xuất "
                + "thành các giao dịch.")
        let day = AppDateFormat.shortDate(input.now, calendar: calendar)
        let weekday = calendar.component(.weekday, from: input.now)
        parts.append(
            "Hôm nay là \(weekday == 1 ? "Chủ nhật" : "thứ \(weekday)"), \(day), "
                + "múi giờ Asia/Ho_Chi_Minh (UTC+7). "
                + "Ngày tương đối (hôm nay, hôm qua, thứ 6 tuần trước…) quy về múi giờ này.")
        if !input.expenseCategories.isEmpty {
            parts.append(
                "Danh mục CHI hợp lệ: " + input.expenseCategories.joined(separator: ", "))
        }
        if !input.incomeCategories.isEmpty {
            parts.append(
                "Danh mục THU hợp lệ: " + input.incomeCategories.joined(separator: ", "))
        }
        if !input.accounts.isEmpty {
            let list = input.accounts
                .map { "\($0.name) (\($0.kind.displayName))" }
                .joined(separator: ", ")
            parts.append("Tài khoản hợp lệ: \(list).")
        }
        if !input.businesses.isEmpty {
            parts.append(
                "Mảng kinh doanh hợp lệ: " + input.businesses.joined(separator: ", "))
        }
        parts.append(
            "Tiền là đồng Việt Nam, số nguyên không phần thập phân. Hiểu cả cách nói tắt: "
                + "85k = 85.000, 1tr2 = 1.200.000, 2 củ = 2.000.000, 3,5 tỷ = 3.500.000.000.")
        parts.append(
            """
            Chỉ trả lời bằng JSON đúng dạng sau, không thêm lời nào khác:
            {"items":[{"kind":"expense","amount":85000,"date":"2026-11-22","note":"...","category":"Ăn uống","account":"Tiền mặt","toAccount":null,"business":null,"confidence":0.9}],"message":null}
            - kind: "expense" (chi), "income" (thu) hoặc "transfer" (chuyển giữa tài khoản của mình).
            - amount: số nguyên đồng, dương. date: ISO yyyy-MM-dd hoặc ISO đầy đủ; thiếu thì dùng hôm nay.
            - category: đúng một tên trong danh sách trên hoặc null. transfer không cần category.
            - account: tài khoản nguồn; toAccount: chỉ cho transfer — tài khoản đích.
            - business: đúng một tên mảng kinh doanh hoặc null. confidence: 0 đến 1.
            - Không trích xuất được gì thì items = [] và đặt "message" (tiếng Việt, ngắn) giải thích vì sao.
            """)
        return parts.joined(separator: "\n")
    }

    // MARK: - Parsing

    /// Name → id tables for validation, grouped by role.
    struct MatchTables: Sendable {
        var expenseCategories: AINameIndex
        var incomeCategories: AINameIndex
        var accounts: AINameIndex
        var businesses: AINameIndex
    }

    /// Parses tolerant model output into drafts. Code fences and surrounding
    /// prose are stripped via `AIJSON`; `items` (or a bare array) are
    /// validated one by one — bad rows become `rejections` with a reason.
    static func parse(
        _ text: String,
        tables: MatchTables,
        now: Date = .now,
        calendar: Calendar = AppCalendar.vietnam
    ) -> AIExtractionResult {
        guard let data = AIJSON.firstValueData(in: text),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return AIExtractionResult(
                drafts: [], rejections: [],
                message: "Không tìm thấy JSON trong phản hồi của AI.")
        }

        var rawItems: [[String: Any]] = []
        var message: String?
        if let dict = object as? [String: Any] {
            message = dict["message"] as? String
            rawItems = (dict["items"] ?? dict["transactions"]) as? [[String: Any]] ?? []
            if rawItems.isEmpty, let single = dict["item"] as? [String: Any] {
                rawItems = [single]
            }
        } else if let array = object as? [[String: Any]] {
            rawItems = array
        }

        var drafts: [AIDraftTransaction] = []
        var rejections: [AIExtractionRejection] = []
        for (index, item) in rawItems.enumerated() {
            switch draft(from: item, tables: tables, now: now, calendar: calendar) {
            case .draft(let draft): drafts.append(draft)
            case .rejected(let reason):
                rejections.append(AIExtractionRejection(index: index, reason: reason))
            }
        }
        return AIExtractionResult(
            drafts: drafts, rejections: rejections, message: message)
    }

    // MARK: - Item validation

    /// One item outcome: a usable draft or a Vietnamese reason it was dropped.
    private enum AIDraftOutcome {
        case draft(AIDraftTransaction)
        case rejected(String)
    }

    private static func draft(
        from item: [String: Any],
        tables: MatchTables,
        now: Date,
        calendar: Calendar
    ) -> AIDraftOutcome {
        // kind
        let kindText = (item["kind"] as? String ?? "expense").lowercased()
        let kind: TransactionKind
        switch kindText {
        case "expense", "chi", "spending": kind = .expense
        case "income", "thu": kind = .income
        case "transfer", "chuyển", "chuyen", "chuyển khoản": kind = .transfer
        default: return .rejected("không hiểu loại giao dịch \"\(kindText)\"")
        }

        // amount — the only mandatory field
        guard let rawAmount = item["amount"],
              let amount = AIAmountParser.parse(rawAmount), amount > 0 else {
            return .rejected("số tiền không hợp lệ hoặc không dương")
        }

        var warnings: [String] = []

        // date: parse, default now, clamp to [now − 10y, now + 1y]
        var date = now
        if let dateText = item["date"] as? String, !dateText.isEmpty {
            if let parsed = parseDate(dateText, calendar: calendar) {
                date = clamped(parsed, now: now, calendar: calendar)
                if date != parsed {
                    warnings.append("ngày nằm ngoài phạm vi hợp lý — đã chỉnh lại")
                }
            } else {
                warnings.append("không đọc được ngày \"\(dateText)\" — dùng hôm nay")
            }
        }

        // names → ids (accept both "category" and "category_name" keys)
        var categoryID: UUID?
        let categoryName = (item["category"] ?? item["category_name"]
            ?? item["categoryName"]) as? String
        if let categoryName, !categoryName.isEmpty {
            categoryID = kind == .income
                ? tables.incomeCategories.match(categoryName)
                : tables.expenseCategories.match(categoryName)
            if categoryID == nil {
                warnings.append("không khớp danh mục \"\(categoryName)\"")
            }
        }
        var accountID: UUID?
        let accountName = (item["account"] ?? item["account_name"]
            ?? item["accountName"]) as? String
        if let accountName, !accountName.isEmpty {
            accountID = tables.accounts.match(accountName)
            if accountID == nil {
                warnings.append("không khớp tài khoản \"\(accountName)\"")
            }
        }
        var toAccountID: UUID?
        let toName = (item["toAccount"] ?? item["to_account"]
            ?? item["destinationAccount"] ?? item["destination"]) as? String
        if let toName, !toName.isEmpty {
            toAccountID = tables.accounts.match(toName)
            if toAccountID == nil {
                warnings.append("không khớp tài khoản đích \"\(toName)\"")
            }
        }
        var businessID: UUID?
        let businessName = (item["business"] ?? item["business_name"]
            ?? item["businessName"]) as? String
        if let businessName, !businessName.isEmpty {
            businessID = tables.businesses.match(businessName)
            if businessID == nil {
                warnings.append("không khớp mảng kinh doanh \"\(businessName)\"")
            }
        }

        if kind == .transfer && toAccountID == nil && toName == nil {
            warnings.append("chuyển khoản thiếu tài khoản đích")
        }

        let confidence: Double
        switch item["confidence"] {
        case let number as NSNumber:
            confidence = min(max(number.doubleValue, 0), 1)
        case let text as String:
            confidence = min(max(Double(text) ?? 0.5, 0), 1)
        default:
            confidence = 0.5
        }

        return .draft(AIDraftTransaction(
            kind: kind,
            amount: amount,
            date: date,
            note: item["note"] as? String ?? "",
            categoryID: categoryID,
            accountID: accountID,
            toAccountID: toAccountID,
            businessID: businessID,
            confidence: confidence,
            warnings: warnings
        ))
    }

    /// ISO-8601 (with or without time), "yyyy-MM-dd", "dd/MM/yyyy",
    /// "dd-MM-yyyy" — interpreted in the Vietnam calendar.
    static func parseDate(_ text: String, calendar: Calendar) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let date = try? Date.ISO8601FormatStyle().parse(trimmed) { return date }
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            .parse(trimmed) { return date }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        for format in ["yyyy-MM-dd", "dd/MM/yyyy", "dd-MM-yyyy", "yyyy/MM/dd",
                       "yyyy-MM-dd HH:mm", "dd/MM/yyyy HH:mm"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }

    /// Sane range: 10 years back to 1 year ahead of `now`.
    private static func clamped(_ date: Date, now: Date, calendar: Calendar) -> Date {
        let lower = calendar.date(byAdding: .year, value: -10, to: now) ?? now
        let upper = calendar.date(byAdding: .year, value: 1, to: now) ?? now
        return min(max(date, lower), upper)
    }
}
