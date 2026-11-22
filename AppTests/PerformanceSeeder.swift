import Foundation
import SwiftData
import FinanceCore
@testable import AMFinance

/// Deterministic large-ledger seeder for performance and correctness
/// tests — models the "VPBank import" profile: one bank account carrying
/// most of ~30k transactions over three years plus cash, credit card,
/// loan, receivable and e-Wallet accounts, 25 categories, 3 businesses
/// and a configurable block of `needsReview` imported rows.
enum PerformanceSeeder {

    struct Dataset {
        let container: ModelContainer
        let context: ModelContext
        /// bank, cash, creditCard, loan, receivable, eWallet (in that order).
        let accounts: [Account]
        let categories: [LedgerCategory]
        let businesses: [Business]
        let transactionCount: Int
        let reviewCount: Int

        var bank: Account { accounts[0] }
        var cash: Account { accounts[1] }
        var card: Account { accounts[2] }
        var loan: Account { accounts[3] }
        var receivable: Account { accounts[4] }
        var eWallet: Account { accounts[5] }
    }

    private static let notes: [String] = [
        "Ăn trưa cơm văn phòng", "Chuyển tiền MOMO", "Grab về nhà",
        "Tiền điện tháng", "Tiền nước", "Netflix", "Siêu thị cuối tuần",
        "Cà phê sáng", "Trả nợ thẻ", "Hoàn tiền GrabFood",
        "Lương tháng", "Thuê nhà", "Đổ xăng", "Phí bảo trì",
        "Ứng hộ khách", "Khách hoàn tiền", "Hoá đơn internet",
        "Mua sắm Tiki", "Spotify premium", "Gym membership",
    ]

    /// Seeds `transactionCount` transactions across ~3 years ending today
    /// in an in-memory container. Deterministic modulo arithmetic keeps the
    /// dataset repeatable so timing runs compare like with like.
    @MainActor
    @discardableResult
    static func seed(
        transactionCount: Int = 30_000,
        reviewCount: Int = 2_000
    ) throws -> Dataset {
        let container = try AppModelContainer.make(inMemory: true)
        let context = ModelContext(container)

        let accounts: [Account] = [
            Account(name: "VPBank *1234", kind: .bank,
                    openingBalance: 250_000_000, colorHex: "0A84FF",
                    sortOrder: 0),
            Account(name: "Tiền mặt", kind: .cash,
                    openingBalance: 5_000_000, colorHex: "34C759",
                    sortOrder: 1),
            Account(name: "Thẻ Visa", kind: .creditCard,
                    openingBalance: -8_000_000, colorHex: "FF9500",
                    sortOrder: 2),
            Account(name: "Vay mua xe", kind: .loan,
                    openingBalance: -120_000_000, colorHex: "FF3B30",
                    sortOrder: 3),
            Account(name: "Khách A — Spa", kind: .receivable,
                    openingBalance: 0, colorHex: "AF52DE",
                    sortOrder: 4),
            Account(name: "MoMo", kind: .eWallet,
                    openingBalance: 800_000, colorHex: "FF2D55",
                    sortOrder: 5),
        ]
        accounts[2].creditLimit = 50_000_000
        accounts[2].statementDay = 20
        accounts[2].graceDays = 15
        accounts[3].loanPrincipal = 180_000_000
        accounts[3].loanTermMonths = 48
        accounts[3].loanStartDate = Date(timeIntervalSinceNow: -300 * 86_400)
        accounts[3].loanPaymentDay = 5
        accounts[3].loanAnnualRatePercent = 11.5
        accounts[3].loanMethodRaw = "annuity"
        accounts[0].externalSource = WalletSyncEngine.externalSource
        accounts[0].externalAccountID = "perf-session"
        for account in accounts { context.insert(account) }

        var categories: [LedgerCategory] = []
        for index in 0..<25 {
            let kind: CategoryKind = index < 5 ? .income : .expense
            let category = LedgerCategory(
                name: kind == .income
                    ? "Thu \(index)" : "Chi \(index)",
                kind: kind,
                icon: "tag.fill",
                colorHex: "0A84FF",
                sortOrder: index
            )
            categories.append(category)
            context.insert(category)
        }
        let expenseCategories = categories.filter { $0.kind == .expense }
        let incomeCategories = categories.filter { $0.kind == .income }

        let businesses = (0..<3).map { index -> Business in
            let business = Business(
                name: "Kinh doanh \(index)", icon: "briefcase.fill",
                colorHex: "34C759", sortOrder: index)
            context.insert(business)
            return business
        }

        let calendar = AppCalendar.vietnam
        let end = calendar.startOfDay(for: .now)
        let totalDays = 3 * 365
        var remainingReview = reviewCount

        for index in 0..<transactionCount {
            // Spread over `totalDays`, newest last so fetch order is real.
            let daysAgo = totalDays - (index * totalDays / transactionCount) - 1
            let date = calendar.date(
                byAdding: .day, value: -max(0, daysAgo), to: end)!
                .addingTimeInterval(TimeInterval(index % 43_200))
            let amount = Int64(50_000 + (index % 200) * 25_000)
            let note = notes[index % notes.count]
            let business = index % 7 == 0 ? businesses[index % 3] : nil

            let transaction: LedgerTransaction
            switch index % 20 {
            case 0, 1, 2:
                // ~15% transfers — between real account pairs.
                let pair: (Account, Account)
                switch index % 3 {
                case 0: pair = (accounts[0], accounts[1])
                case 1: pair = (accounts[0], accounts[2])
                default: pair = (accounts[1], accounts[4])
                }
                transaction = LedgerTransaction(
                    kind: .transfer, amount: amount, date: date, note: note,
                    account: pair.0, toAccount: pair.1, business: business)
            case 3, 4, 5, 6:
                // ~20% income.
                let account = index % 4 == 3 ? accounts[5] : accounts[index % 2]
                transaction = LedgerTransaction(
                    kind: .income, amount: amount, date: date, note: note,
                    account: account,
                    category: incomeCategories[index % incomeCategories.count],
                    business: business)
            default:
                // ~65% expense across all spend-capable accounts.
                let pool = [accounts[0], accounts[0], accounts[0], accounts[0],
                            accounts[2], accounts[2], accounts[1],
                            accounts[4], accounts[3], accounts[5]]
                let account = pool[index % pool.count]
                transaction = LedgerTransaction(
                    kind: .expense, amount: amount, date: date, note: note,
                    account: account,
                    category: expenseCategories[index % expenseCategories.count],
                    business: business)
            }

            if remainingReview > 0
                && transaction.account?.id == accounts[0].id
                && index > transactionCount / 3 {
                transaction.needsReview = true
                transaction.externalSource = WalletSyncEngine.externalSource
                transaction.externalID = String(format: "ext-%08d", index)
                remainingReview -= 1
            }
            context.insert(transaction)
        }
        try context.save()
        return Dataset(
            container: container,
            context: context,
            accounts: accounts,
            categories: categories,
            businesses: businesses,
            transactionCount: transactionCount,
            reviewCount: reviewCount - remainingReview
        )
    }
}
