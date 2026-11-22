import Foundation
import FinanceCore

/// Lightweight snapshot of the owner's finances — the only input the
/// context builder needs, so feature screens assemble it however they like
/// (SwiftData queries, report structs…). All amounts are đồng, signed where
/// the ledger convention is signed.
struct AIFinanceSnapshot: Sendable, Equatable {
    /// "Tháng 11/2026", "Tuần này", "Từ 01/11 đến 22/11"…
    var periodLabel: String
    var income: Int64
    var expense: Int64

    struct AICategoryTotal: Sendable, Equatable {
        var name: String
        var kind: CategoryKind
        var amount: Int64
    }
    struct AIBusinessTotal: Sendable, Equatable {
        var name: String
        var income: Int64
        var expense: Int64
        var profit: Int64 { income - expense }
    }
    struct AIAccountLine: Sendable, Equatable {
        var name: String
        var kind: AccountKind
        /// Signed balance — negative on liability kinds means money owed.
        var balance: Int64
    }
    struct AIBudgetLine: Sendable, Equatable {
        /// nil = the overall budget.
        var name: String?
        var spent: Int64
        var limit: Int64
    }
    struct AIDueLine: Sendable, Equatable {
        var title: String
        var date: Date
        var amount: Int64
    }
    struct AIRecurringLine: Sendable, Equatable {
        var name: String
        var amount: Int64
        /// "mỗi tháng", "hàng tuần"…
        var scheduleLabel: String
    }
    struct AITransactionLine: Sendable, Equatable {
        var date: Date
        /// Signed: negative = chi, positive = thu.
        var signedAmount: Int64
        var categoryName: String?
        var businessName: String?
        var accountName: String?
        var note: String?
    }

    var categories: [AICategoryTotal] = []
    var businesses: [AIBusinessTotal] = []
    var accounts: [AIAccountLine] = []
    var budgets: [AIBudgetLine] = []
    var upcomingDues: [AIDueLine] = []
    var recurring: [AIRecurringLine] = []
    var transactions: [AITransactionLine] = []

    init(periodLabel: String, income: Int64, expense: Int64) {
        self.periodLabel = periodLabel
        self.income = income
        self.expense = expense
    }
}

/// What the owner allows the model to see.
struct AIFinancePrivacyOptions: Sendable, Equatable {
    /// Include the per-transaction list at all.
    var includeTransactions: Bool = true
    /// Include each transaction's free-text note.
    var includeNotes: Bool = false
    /// Include real account names — off means only the kind ("Ngân hàng").
    var includeAccountNames: Bool = true

    static let open = AIFinancePrivacyOptions()
    static let minimal = AIFinancePrivacyOptions(
        includeTransactions: false, includeNotes: false,
        includeAccountNames: false)
}

/// The built context: the exact text that would be sent plus how the
/// character budget cut the transaction list.
struct AIFinanceContext: Sendable, Equatable {
    var text: String
    var includedTransactions: Int
    var omittedTransactions: Int
}

/// Builds a compact Vietnamese summary of `AIFinanceSnapshot` for the
/// model's prompt. Sections are fixed lines; the transaction list is the
/// first thing truncated when the `characterBudget` runs out, and the text
/// always states how many rows were omitted.
enum AIFinanceContextBuilder {
    static let defaultCharacterBudget = 6_000

    /// The exact text a screen can preview before sending.
    static func outgoingText(
        snapshot: AIFinanceSnapshot,
        options: AIFinancePrivacyOptions = .open,
        characterBudget: Int = defaultCharacterBudget,
        calendar: Calendar = AppCalendar.vietnam
    ) -> String {
        build(
            snapshot: snapshot, options: options,
            characterBudget: characterBudget, calendar: calendar
        ).text
    }

    static func build(
        snapshot: AIFinanceSnapshot,
        options: AIFinancePrivacyOptions = .open,
        characterBudget: Int = defaultCharacterBudget,
        calendar: Calendar = AppCalendar.vietnam
    ) -> AIFinanceContext {
        let budget = max(0, characterBudget)
        let head = headerLines(snapshot: snapshot, options: options, calendar: calendar)
        var body = head.joined(separator: "\n")

        let transactionLines = options.includeTransactions
            ? snapshot.transactions.map {
                transactionLine($0, options: options, calendar: calendar)
            }
            : []

        var included = 0
        for (index, line) in transactionLines.enumerated() {
            // Reserve room for the "… omitted" marker that would follow this
            // line, so the marker always fits when truncation stops here.
            let remaining = transactionLines.count - index - 1
            let marker = remaining > 0
                ? "\n- … đã lược bớt \(remaining) giao dịch để vừa giới hạn." : ""
            if (body + "\n" + line + marker).count > budget { break }
            body += "\n" + line
            included += 1
        }

        let omitted = transactionLines.count - included
        if omitted > 0 {
            let marker = "\n- … đã lược bớt \(omitted) giao dịch để vừa giới hạn."
            if (body + marker).count <= budget { body += marker }
        }
        if body.count > budget {
            body = String(body.prefix(max(0, budget - 1))) + "…"
        }
        return AIFinanceContext(
            text: body,
            includedTransactions: included,
            omittedTransactions: omitted
        )
    }

    // MARK: - Fixed sections

    private static func headerLines(
        snapshot: AIFinanceSnapshot,
        options: AIFinancePrivacyOptions,
        calendar: Calendar
    ) -> [String] {
        var lines: [String] = ["Bối cảnh tài chính — \(snapshot.periodLabel)"]

        let net = snapshot.income - snapshot.expense
        lines.append(
            "Thu \(VND.compact(snapshot.income)) · "
                + "Chi \(VND.compact(snapshot.expense)) · "
                + "Ròng \(signed(net))")

        let expenseCats = snapshot.categories
            .filter { $0.kind == .expense }
            .sorted { $0.amount > $1.amount }
        if !expenseCats.isEmpty {
            lines.append(
                "Chi theo danh mục: "
                    + expenseCats.map { "\($0.name) \(VND.compact($0.amount))" }
                        .joined(separator: "; "))
        }
        let incomeCats = snapshot.categories
            .filter { $0.kind == .income }
            .sorted { $0.amount > $1.amount }
        if !incomeCats.isEmpty {
            lines.append(
                "Thu theo danh mục: "
                    + incomeCats.map { "\($0.name) \(VND.compact($0.amount))" }
                        .joined(separator: "; "))
        }

        if !snapshot.businesses.isEmpty {
            let parts = snapshot.businesses.map { business in
                let profit = business.profit
                let label = profit >= 0 ? "lãi" : "lỗ"
                return "\(business.name) \(label) \(VND.compact(abs(profit)))"
                    + " (thu \(VND.compact(business.income)),"
                    + " chi \(VND.compact(business.expense)))"
            }
            lines.append("Lãi lỗ theo mảng: " + parts.joined(separator: "; "))
        }

        if !snapshot.accounts.isEmpty {
            var kindCounts: [AccountKind: Int] = [:]
            let parts = snapshot.accounts.map { account -> String in
                if options.includeAccountNames {
                    return "\(account.name) (\(account.kind.displayName.lowercased()))"
                        + " \(signed(account.balance))"
                }
                let count = (kindCounts[account.kind] ?? 0) + 1
                kindCounts[account.kind] = count
                return "\(account.kind.displayName) #\(count) \(signed(account.balance))"
            }
            lines.append("Tài khoản: " + parts.joined(separator: "; "))
        }

        let debts = snapshot.accounts.filter { $0.kind.isLiability && $0.balance != 0 }
        if !debts.isEmpty {
            let parts = debts.map { account -> String in
                let label = options.includeAccountNames
                    ? account.name : account.kind.displayName
                return account.balance < 0
                    ? "\(label) còn nợ \(VND.compact(-account.balance))"
                    : "\(label) dư \(VND.compact(account.balance))"
            }
            lines.append("Nợ & thẻ: " + parts.joined(separator: "; "))
        }

        if !snapshot.budgets.isEmpty {
            let parts = snapshot.budgets.map { budget -> String in
                let name = budget.name ?? "Chung"
                let percent = budget.limit > 0
                    ? Int((Double(budget.spent) / Double(budget.limit) * 100).rounded())
                    : 0
                return "\(name) \(VND.compact(budget.spent))/"
                    + "\(VND.compact(budget.limit)) (\(percent)%)"
            }
            lines.append("Ngân sách: " + parts.joined(separator: "; "))
        }

        if !snapshot.upcomingDues.isEmpty {
            let parts = snapshot.upcomingDues.map {
                "\($0.title) \(AppDateFormat.shortDate($0.date, calendar: calendar))"
                    + " \(VND.compact($0.amount))"
            }
            lines.append("Sắp đến hạn: " + parts.joined(separator: "; "))
        }

        if !snapshot.recurring.isEmpty {
            let parts = snapshot.recurring.map {
                "\($0.name) \(VND.compact($0.amount)) \($0.scheduleLabel)"
            }
            lines.append("Định kỳ: " + parts.joined(separator: "; "))
        }

        if options.includeTransactions && !snapshot.transactions.isEmpty {
            lines.append("Giao dịch trong kỳ (\(snapshot.transactions.count)):")
        }
        return lines
    }

    private static func transactionLine(
        _ line: AIFinanceSnapshot.AITransactionLine,
        options: AIFinancePrivacyOptions,
        calendar: Calendar
    ) -> String {
        var parts = [
            AppDateFormat.shortDate(line.date, calendar: calendar),
            signed(line.signedAmount),
        ]
        if let category = line.categoryName, !category.isEmpty {
            parts.append(category)
        }
        if let business = line.businessName, !business.isEmpty {
            parts.append(business)
        }
        if options.includeAccountNames,
           let account = line.accountName, !account.isEmpty {
            parts.append(account)
        }
        if options.includeNotes,
           let note = line.note?.trimmingCharacters(in: .whitespacesAndNewlines),
           !note.isEmpty {
            parts.append("“\(note)”")
        }
        return "- " + parts.joined(separator: " · ")
    }

    /// "+12 tr" / "-3 tr" — compact with an explicit sign for the model.
    private static func signed(_ dong: Int64) -> String {
        dong >= 0 ? "+\(VND.compact(dong))" : "-\(VND.compact(-dong))"
    }
}
