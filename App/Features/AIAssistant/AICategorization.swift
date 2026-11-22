import Foundation
import FinanceCore

/// One bank transaction row the model should classify — `id` is whatever
/// key the caller uses (UUID string, external id…); `signedAmount` is the
/// bank's own sign convention (negative = money out).
struct AIBankRow: Sendable, Equatable {
    var id: String
    var signedAmount: Int64
    var note: String
}

/// What the model picked for one row.
struct AICategorizationSuggestion: Sendable, Equatable {
    enum Target: Sendable, Equatable {
        case category(UUID)
        case business(UUID)
        /// Money moving between the owner's own accounts — skip on import.
        case internalTransfer
    }
    var target: Target
    var confidence: Double
}

/// Prompt + parser for bulk classifying bank transactions into a category,
/// a business, or "internal transfer". Output is keyed by the caller's row
/// id; unknown ids and names are ignored.
enum AICategorization {

    static func systemPrompt(
        expenseCategories: [String],
        incomeCategories: [String],
        businesses: [String]
    ) -> String {
        var parts: [String] = []
        parts.append(
            "Bạn là trợ lý phân loại sao kê ngân hàng của một ứng dụng quản lý tài chính ở "
                + "Việt Nam. Mỗi giao dịch có id, số tiền có dấu (âm = tiền ra, "
                + "dương = tiền vào, đơn vị đồng) và nội dung ghi chú của ngân hàng.")
        if !expenseCategories.isEmpty {
            parts.append(
                "Danh mục CHI hợp lệ: " + expenseCategories.joined(separator: ", "))
        }
        if !incomeCategories.isEmpty {
            parts.append(
                "Danh mục THU hợp lệ: " + incomeCategories.joined(separator: ", "))
        }
        if !businesses.isEmpty {
            parts.append(
                "Mảng kinh doanh hợp lệ (chọn khi giao dịch thuộc một mảng): "
                    + businesses.joined(separator: ", "))
        }
        parts.append(
            """
            Với mỗi giao dịch hãy chọn MỘT trong ba:
            - "category": đúng một tên danh mục ở trên (khớp chiều tiền: âm → danh mục chi, dương → danh mục thu)
            - "business": đúng một tên mảng kinh doanh ở trên
            - "transfer": true — khi đó là tiền chuyển giữa các tài khoản của chính chủ nhân \
            (trả thẻ, rút tiền, chuyển tiết kiệm…), không phải thu chi
            Chỉ trả lời bằng JSON đúng dạng sau, không thêm lời nào khác:
            {"suggestions":[{"id":"t1","category":"Ăn uống","business":null,"transfer":false,"confidence":0.9}]}
            """)
        return parts.joined(separator: "\n")
    }

    /// The user-turn payload: a compact JSON array the model maps over.
    static func userPrompt(rows: [AIBankRow]) -> String {
        var items: [[String: Any]] = []
        items.reserveCapacity(rows.count)
        for row in rows {
            items.append([
                "id": row.id,
                "amount": row.signedAmount,
                "note": row.note,
            ])
        }
        guard let data = try? JSONSerialization.data(withJSONObject: items),
              let json = String(data: data, encoding: .utf8)
        else { return "[]" }
        return json
    }

    /// Parses the reply. Tolerant of code fences/prose via `AIJSON`; a
    /// suggestion is dropped when its id is unknown, when the named
    /// category/business does not exist, or when nothing was chosen at all.
    static func parse(
        _ text: String,
        validIDs: Set<String>,
        expenseCategories: AINameIndex,
        incomeCategories: AINameIndex,
        businesses: AINameIndex
    ) -> [String: AICategorizationSuggestion] {
        guard let data = AIJSON.firstValueData(in: text),
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return [:] }

        var raw: [[String: Any]] = []
        if let dict = object as? [String: Any] {
            raw = (dict["suggestions"] ?? dict["items"] ?? dict["results"])
                as? [[String: Any]] ?? []
        } else if let array = object as? [[String: Any]] {
            raw = array
        }

        var result: [String: AICategorizationSuggestion] = [:]
        for item in raw {
            guard let id = item["id"] as? String, validIDs.contains(id) else {
                continue
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

            var target: AICategorizationSuggestion.Target?
            let isTransfer = (item["transfer"] as? Bool)
                ?? ((item["kind"] as? String)?.lowercased() == "transfer")
                || ((item["type"] as? String)?.lowercased() == "transfer")
            if isTransfer {
                target = .internalTransfer
            } else if let name = (item["business"] ?? item["business_name"])
                        as? String, !name.isEmpty,
                      let id = businesses.match(name) {
                target = .business(id)
            } else if let name = (item["category"] ?? item["category_name"])
                        as? String, !name.isEmpty {
                if let id = expenseCategories.match(name) {
                    target = .category(id)
                } else if let id = incomeCategories.match(name) {
                    target = .category(id)
                }
            }
            guard let target else { continue }
            result[id] = AICategorizationSuggestion(
                target: target, confidence: confidence)
        }
        return result
    }
}
