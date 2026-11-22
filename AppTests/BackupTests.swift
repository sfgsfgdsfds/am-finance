import Testing
import SwiftData
import Foundation
import FinanceCore
@testable import AMFinance

@MainActor
struct BackupTests {

    private let calendar = AppCalendar.vietnam

    private func makeContext() throws -> ModelContext {
        ModelContext(try AppModelContainer.make(inMemory: true))
    }

    private func fetchAll<T: PersistentModel>(_ type: T.Type, in context: ModelContext) throws -> [T] {
        try context.fetch(FetchDescriptor<T>())
    }

    /// A moment in Asia/Ho_Chi_Minh — the zone the CSV renders dates in.
    private func day(
        _ year: Int, _ month: Int, _ dayOfMonth: Int,
        _ hour: Int = 0, _ minute: Int = 0
    ) -> Date {
        calendar.date(from: DateComponents(
            year: year, month: month, day: dayOfMonth, hour: hour, minute: minute
        ))!
    }

    // MARK: - Round trip

    @Test func replaceRestoreRoundTripsEverything() throws {
        let context = try makeContext()
        try SeedData.seedIfNeeded(context: context)

        let bank = Account(name: "Ngân hàng ACB", kind: .bank, openingBalance: 5_000_000,
                           icon: "building.columns.fill", colorHex: "0A84FF",
                           note: "Tài khoản chính", sortOrder: 10)
        bank.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let card = Account(name: "Thẻ Visa", kind: .creditCard, openingBalance: -2_000_000)
        card.creditLimit = 50_000_000
        card.statementDay = 20
        card.graceDays = 45
        card.createdAt = Date(timeIntervalSince1970: 1_700_000_100)
        let loan = Account(name: "Vay mua xe", kind: .loan, openingBalance: -120_000_000)
        loan.loanPrincipal = 150_000_000
        loan.loanAnnualRatePercent = 8.5
        loan.loanTermMonths = 60
        loan.loanStartDate = Date(timeIntervalSince1970: 1_690_000_000)
        loan.loanPaymentDay = 5
        loan.loanMethodRaw = "annuity"
        loan.externalSource = "bank-link"
        loan.externalAccountID = "LN-001"
        loan.createdAt = Date(timeIntervalSince1970: 1_700_000_200)
        for account in [bank, card, loan] { context.insert(account) }
        context.insert(LoanRateChange(
            fromInstallment: 13, annualRatePercent: 11.5, account: loan
        ))

        let category = LedgerCategory(name: "Cà phê", kind: .expense,
                                      icon: "cup.and.saucer.fill", colorHex: "A2845E", sortOrder: 99)
        context.insert(category)
        let seededBusiness = try #require(fetchAll(Business.self, in: context).first)
        let incomeCategory = try #require(fetchAll(LedgerCategory.self, in: context).first {
            $0.kindRaw == CategoryKind.income.rawValue
        })

        let purchase = LedgerTransaction(
            kind: .expense, amount: 65_000,
            date: Date(timeIntervalSince1970: 1_763_000_000),
            note: "Cà phê, bánh mì", account: bank, category: category
        )
        purchase.createdAt = Date(timeIntervalSince1970: 1_763_000_001)
        purchase.updatedAt = Date(timeIntervalSince1970: 1_763_000_002)
        let payoff = LedgerTransaction(
            kind: .transfer, amount: 2_000_000,
            date: Date(timeIntervalSince1970: 1_764_000_000),
            note: "Trả thẻ", account: bank, toAccount: card,
            business: seededBusiness, needsReview: true
        )
        payoff.externalSource = "import-csv"
        payoff.externalID = "tx-99"
        payoff.createdAt = Date(timeIntervalSince1970: 1_764_000_001)
        payoff.updatedAt = Date(timeIntervalSince1970: 1_764_000_002)
        let salary = LedgerTransaction(
            kind: .income, amount: 30_000_000,
            date: Date(timeIntervalSince1970: 1_765_000_000),
            note: "Lương tháng 11", account: bank, category: incomeCategory,
            business: seededBusiness
        )
        salary.createdAt = Date(timeIntervalSince1970: 1_765_000_001)
        salary.updatedAt = Date(timeIntervalSince1970: 1_765_000_002)
        for transaction in [purchase, payoff, salary] { context.insert(transaction) }
        try context.save()

        // Capture everything the assertions compare against: after the
        // replace-restore the original objects are deleted.
        let bankID = bank.id, cardID = card.id, loanID = loan.id
        let categoryID = category.id, businessID = seededBusiness.id
        let incomeCategoryID = incomeCategory.id
        let purchaseID = purchase.id, purchaseCreatedAt = purchase.createdAt
        let purchaseUpdatedAt = purchase.updatedAt
        let payoffID = payoff.id, salaryID = salary.id
        let rateChangeID = try #require(loan.loanRateChanges?.first).id
        let accountIDs = Set(try fetchAll(Account.self, in: context).map(\.id))

        let data = try BackupCodec.encode(
            context: context, exportedAt: Date(timeIntervalSince1970: 1_763_791_500)
        )
        let document = try BackupCodec.decode(data)
        #expect(document.formatVersion == BackupCodec.formatVersion)

        let result = try BackupRestorer.restore(document, mode: .replace, into: context)

        let accounts = try fetchAll(Account.self, in: context)
        let categories = try fetchAll(LedgerCategory.self, in: context)
        let businesses = try fetchAll(Business.self, in: context)
        let restored = try fetchAll(LedgerTransaction.self, in: context)

        #expect(accounts.count == 4)    // 1 seeded + 3 added
        #expect(categories.count == 22) // 21 seeded + 1 added
        #expect(businesses.count == 3)
        #expect(restored.count == 3)
        #expect(result.inserted == 4 + 22 + 3 + 3 + 1) // + the rate change
        #expect(result.updated == 0)
        #expect(result.skipped == 0)
        #expect(Set(accounts.map(\.id)) == accountIDs)

        let rBank = try #require(accounts.first { $0.id == bankID })
        #expect(rBank.name == "Ngân hàng ACB")
        #expect(rBank.kindRaw == "bank")
        #expect(rBank.openingBalance == 5_000_000)
        #expect(rBank.note == "Tài khoản chính")
        #expect(rBank.createdAt == Date(timeIntervalSince1970: 1_700_000_000))

        let rCard = try #require(accounts.first { $0.id == cardID })
        #expect(rCard.creditLimit == 50_000_000)
        #expect(rCard.statementDay == 20)
        #expect(rCard.graceDays == 45)

        let rLoan = try #require(accounts.first { $0.id == loanID })
        #expect(rLoan.loanPrincipal == 150_000_000)
        #expect(rLoan.loanAnnualRatePercent == 8.5)
        #expect(rLoan.loanTermMonths == 60)
        #expect(rLoan.loanStartDate == Date(timeIntervalSince1970: 1_690_000_000))
        #expect(rLoan.loanPaymentDay == 5)
        #expect(rLoan.loanMethodRaw == "annuity")
        #expect(rLoan.externalSource == "bank-link")
        #expect(rLoan.externalAccountID == "LN-001")

        let rateChanges = try fetchAll(LoanRateChange.self, in: context)
        let rChange = try #require(rateChanges.first { $0.id == rateChangeID })
        #expect(rateChanges.count == 1)
        #expect(rChange.fromInstallment == 13)
        #expect(rChange.annualRatePercent == 11.5)
        #expect(rChange.account?.id == loanID)
        #expect(rLoan.loanRateChanges?.count == 1)

        let rCategory = try #require(categories.first { $0.id == categoryID })
        #expect(rCategory.name == "Cà phê")
        #expect(rCategory.icon == "cup.and.saucer.fill")

        let rPurchase = try #require(restored.first { $0.id == purchaseID })
        #expect(rPurchase.kindRaw == "expense")
        #expect(rPurchase.amount == 65_000)
        #expect(rPurchase.note == "Cà phê, bánh mì")
        #expect(rPurchase.account?.id == bankID)
        #expect(rPurchase.category?.id == categoryID)
        #expect(rPurchase.toAccount == nil)
        #expect(rPurchase.createdAt == purchaseCreatedAt)
        #expect(rPurchase.updatedAt == purchaseUpdatedAt)

        let rPayoff = try #require(restored.first { $0.id == payoffID })
        #expect(rPayoff.account?.id == bankID)
        #expect(rPayoff.toAccount?.id == cardID)
        #expect(rPayoff.business?.id == businessID)
        #expect(rPayoff.needsReview)
        #expect(rPayoff.externalSource == "import-csv")
        #expect(rPayoff.externalID == "tx-99")

        let rSalary = try #require(restored.first { $0.id == salaryID })
        #expect(rSalary.account?.id == bankID)
        #expect(rSalary.category?.id == incomeCategoryID)

        // Balances are identical after the round trip.
        #expect(rBank.balance == 32_935_000)
        #expect(rCard.balance == 0)
        #expect(rLoan.balance == -120_000_000)
    }

    // MARK: - Merge

    @Test func mergeUpsertsAndPrefersNewerUpdatedAt() throws {
        let context = try makeContext()
        let cash = Account(name: "Tiền mặt", kind: .cash, openingBalance: 1_000_000)
        let food = LedgerCategory(name: "Ăn uống", kind: .expense)
        context.insert(cash)
        context.insert(food)

        let localNewer = LedgerTransaction(
            kind: .expense, amount: 10_000,
            date: Date(timeIntervalSince1970: 100),
            note: "bản địa mới hơn", account: cash, category: food
        )
        localNewer.createdAt = Date(timeIntervalSince1970: 50)
        localNewer.updatedAt = Date(timeIntervalSince1970: 2_000)
        let localOlder = LedgerTransaction(
            kind: .expense, amount: 20_000,
            date: Date(timeIntervalSince1970: 100),
            note: "bản địa cũ hơn", account: cash
        )
        localOlder.createdAt = Date(timeIntervalSince1970: 50)
        localOlder.updatedAt = Date(timeIntervalSince1970: 1_000)
        context.insert(localNewer)
        context.insert(localOlder)
        try context.save()

        let newAccountID = UUID()
        let newBusinessID = UUID()
        let newTransactionID = UUID()

        // Incoming document — DTOs built from detached models then tweaked.
        var updatedAccount = BackupAccount(cash)
        updatedAccount.name = "Tiền mặt mới"
        updatedAccount.kindRaw = "bank"
        updatedAccount.openingBalance = 99_000

        var skipped = BackupTransaction(localNewer)
        skipped.note = "bản sao lưu cũ hơn"
        skipped.amount = 1
        skipped.updatedAt = Date(timeIntervalSince1970: 1_500) // older than local 2_000

        var winner = BackupTransaction(localOlder)
        winner.note = "bản sao lưu mới hơn"
        winner.amount = 21_000
        winner.updatedAt = Date(timeIntervalSince1970: 1_700) // newer than local 1_000

        var inserted = BackupTransaction(
            LedgerTransaction(id: newTransactionID, kind: .income, amount: 7_000)
        )
        inserted.accountID = newAccountID
        inserted.businessID = newBusinessID
        inserted.createdAt = Date(timeIntervalSince1970: 60)
        inserted.updatedAt = Date(timeIntervalSince1970: 60)

        var updatedCategory = BackupCategory(food)
        updatedCategory.name = "Ăn nhậu"
        updatedCategory.kindRaw = "income"

        let document = BackupDocument(
            formatVersion: 1, exportedAt: .now, appVersion: "test",
            accounts: [
                updatedAccount,
                BackupAccount(Account(id: newAccountID, name: "Ví mới", kind: .eWallet)),
            ],
            categories: [updatedCategory],
            businesses: [BackupBusiness(Business(id: newBusinessID, name: "Kinh doanh mới"))],
            transactions: [skipped, winner, inserted]
        )

        let result = try BackupRestorer.restore(document, mode: .merge, into: context)

        #expect(result.inserted == 3) // new account + business + transaction
        #expect(result.updated == 3)  // account + category + transaction
        #expect(result.skipped == 1)  // the transaction local was newer for

        #expect(cash.name == "Tiền mặt mới")
        #expect(cash.kindRaw == "bank")
        #expect(cash.openingBalance == 99_000)
        #expect(food.name == "Ăn nhậu")
        #expect(food.kindRaw == "income")

        // Local row with the newer updatedAt is untouched; the older one
        // was overwritten by the backup copy.
        #expect(localNewer.note == "bản địa mới hơn")
        #expect(localNewer.amount == 10_000)
        #expect(localOlder.note == "bản sao lưu mới hơn")
        #expect(localOlder.amount == 21_000)

        let restored = try fetchAll(LedgerTransaction.self, in: context)
        #expect(restored.count == 3)
        let newTransaction = try #require(restored.first { $0.id == newTransactionID })
        #expect(newTransaction.account?.id == newAccountID)
        #expect(newTransaction.business?.id == newBusinessID)
        #expect(newTransaction.kindRaw == "income")
        #expect(try fetchAll(Account.self, in: context).count == 2)
        #expect(try fetchAll(Business.self, in: context).count == 1)
    }

    // MARK: - Loan rate changes

    @Test func mergeUpsertsLoanRateChangesAndRelinksAccount() throws {
        let context = try makeContext()
        let loan = Account(name: "Vay cũ", kind: .loan, openingBalance: -120_000_000)
        context.insert(loan)
        let existing = LoanRateChange(
            fromInstallment: 13, annualRatePercent: 11.5, account: loan
        )
        context.insert(existing)
        try context.save()

        let newLoanID = UUID()
        let newChangeID = UUID()

        var updated = BackupLoanRateChange(existing)
        updated.fromInstallment = 14
        updated.annualRatePercent = 18.0

        var inserted = BackupLoanRateChange(
            LoanRateChange(id: newChangeID, fromInstallment: 5, annualRatePercent: 9.0)
        )
        inserted.accountID = newLoanID

        let document = BackupDocument(
            formatVersion: 2, exportedAt: .now, appVersion: "test",
            accounts: [BackupAccount(Account(id: newLoanID, name: "Vay mới", kind: .loan))],
            categories: [], businesses: [], transactions: [],
            loanRateChanges: [updated, inserted]
        )

        let result = try BackupRestorer.restore(document, mode: .merge, into: context)

        #expect(result.inserted == 2) // new loan account + new rate change
        #expect(result.updated == 1)  // the existing rate change
        #expect(existing.fromInstallment == 14)
        #expect(existing.annualRatePercent == 18.0)
        #expect(existing.account?.id == loan.id)

        let changes = try fetchAll(LoanRateChange.self, in: context)
        #expect(changes.count == 2)
        let newChange = try #require(changes.first { $0.id == newChangeID })
        #expect(newChange.fromInstallment == 5)
        #expect(newChange.annualRatePercent == 9.0)
        #expect(newChange.account?.id == newLoanID)
    }

    // MARK: - Budgets and recurring rules

    @Test func replaceRestoreRoundTripsBudgetsAndRecurringRules() throws {
        let context = try makeContext()
        let bank = Account(name: "Ngân hàng", kind: .bank, openingBalance: 5_000_000)
        let wallet = Account(name: "Ví", kind: .eWallet)
        let food = LedgerCategory(name: "Ăn uống", kind: .expense)
        let web = Business(name: "Làm web")
        context.insert(bank)
        context.insert(wallet)
        context.insert(food)
        context.insert(web)

        let overall = Budget(monthlyLimit: 10_000_000, note: "Tổng chi")
        overall.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let foodBudget = Budget(monthlyLimit: 3_000_000, isActive: false,
                                note: "Ăn uống", category: food)
        foodBudget.createdAt = Date(timeIntervalSince1970: 1_700_000_100)
        context.insert(overall)
        context.insert(foodBudget)

        let rule = RecurringRule(
            title: "Thuê nhà", kind: .expense, amount: 7_000_000,
            note: "Trả định kỳ", account: bank, category: food, business: web,
            frequency: .monthly, interval: 2,
            startDate: day(2026, 1, 5), endDate: day(2027, 1, 5),
            maximumOccurrences: 12,
            lastGeneratedDate: day(2026, 9, 5),
            autoCreate: true, isActive: true
        )
        rule.createdAt = Date(timeIntervalSince1970: 1_700_000_200)
        let topUp = RecurringRule(
            title: "Nạp ví", kind: .transfer, amount: 500_000,
            account: bank, toAccount: wallet,
            frequency: .weekly,
            startDate: day(2026, 11, 2),
            autoCreate: false, isActive: false
        )
        topUp.createdAt = Date(timeIntervalSince1970: 1_700_000_300)
        context.insert(rule)
        context.insert(topUp)
        try context.save()

        let overallID = overall.id, foodBudgetID = foodBudget.id
        let ruleID = rule.id, topUpID = topUp.id
        let bankID = bank.id, walletID = wallet.id
        let foodID = food.id, webID = web.id

        let data = try BackupCodec.encode(
            context: context, exportedAt: Date(timeIntervalSince1970: 1_763_791_500)
        )
        let document = try BackupCodec.decode(data)
        #expect(document.budgets.count == 2)
        #expect(document.recurringRules.count == 2)

        let result = try BackupRestorer.restore(document, mode: .replace, into: context)
        #expect(result.inserted == 2 + 1 + 1 + 2 + 2) // accounts+category+business+budgets+rules

        let budgets = try fetchAll(Budget.self, in: context)
        #expect(budgets.count == 2)
        let rOverall = try #require(budgets.first { $0.id == overallID })
        #expect(rOverall.monthlyLimit == 10_000_000)
        #expect(rOverall.isActive)
        #expect(rOverall.note == "Tổng chi")
        #expect(rOverall.category == nil)
        #expect(rOverall.createdAt == Date(timeIntervalSince1970: 1_700_000_000))

        let rFoodBudget = try #require(budgets.first { $0.id == foodBudgetID })
        #expect(rFoodBudget.monthlyLimit == 3_000_000)
        #expect(!rFoodBudget.isActive)
        #expect(rFoodBudget.category?.id == foodID)

        let rules = try fetchAll(RecurringRule.self, in: context)
        #expect(rules.count == 2)
        let rRule = try #require(rules.first { $0.id == ruleID })
        #expect(rRule.title == "Thuê nhà")
        #expect(rRule.kindRaw == "expense")
        #expect(rRule.amount == 7_000_000)
        #expect(rRule.note == "Trả định kỳ")
        #expect(rRule.account?.id == bankID)
        #expect(rRule.toAccount == nil)
        #expect(rRule.category?.id == foodID)
        #expect(rRule.business?.id == webID)
        #expect(rRule.frequencyRaw == "monthly")
        #expect(rRule.interval == 2)
        #expect(rRule.startDate == day(2026, 1, 5))
        #expect(rRule.endDate == day(2027, 1, 5))
        #expect(rRule.maximumOccurrences == 12)
        #expect(rRule.lastGeneratedDate == day(2026, 9, 5))
        #expect(rRule.autoCreate)
        #expect(rRule.isActive)
        #expect(rRule.createdAt == Date(timeIntervalSince1970: 1_700_000_200))

        let rTopUp = try #require(rules.first { $0.id == topUpID })
        #expect(rTopUp.kindRaw == "transfer")
        #expect(rTopUp.account?.id == bankID)
        #expect(rTopUp.toAccount?.id == walletID)
        #expect(rTopUp.frequencyRaw == "weekly")
        #expect(rTopUp.interval == 1)
        #expect(rTopUp.endDate == nil)
        #expect(rTopUp.maximumOccurrences == nil)
        #expect(rTopUp.lastGeneratedDate == nil)
        #expect(!rTopUp.autoCreate)
        #expect(!rTopUp.isActive)
    }

    @Test func mergeUpsertsBudgetsAndRecurringRulesAndRelinks() throws {
        let context = try makeContext()
        let food = LedgerCategory(name: "Ăn uống", kind: .expense)
        let bank = Account(name: "Ngân hàng", kind: .bank)
        context.insert(food)
        context.insert(bank)

        let budget = Budget(monthlyLimit: 1_000_000, category: food)
        let rule = RecurringRule(
            title: "Gói mềm", kind: .expense, amount: 100_000,
            account: bank, category: food,
            frequency: .monthly, startDate: day(2026, 1, 5)
        )
        context.insert(budget)
        context.insert(rule)
        try context.save()

        let newCategoryID = UUID()
        let newBudgetID = UUID()
        let newRuleID = UUID()

        var updatedBudget = BackupBudget(budget)
        updatedBudget.monthlyLimit = 2_000_000
        updatedBudget.isActive = false
        updatedBudget.note = "đổi"

        var updatedRule = BackupRecurringRule(rule)
        updatedRule.title = "Gói mềm mới"
        updatedRule.amount = 150_000
        updatedRule.frequencyRaw = "weekly"
        updatedRule.maximumOccurrences = 8

        var insertedBudget = BackupBudget(
            Budget(id: newBudgetID, monthlyLimit: 5_000_000)
        )
        insertedBudget.categoryID = newCategoryID

        var insertedRule = BackupRecurringRule(
            RecurringRule(id: newRuleID, title: "Mới", kind: .income,
                          amount: 9_000_000, frequency: .yearly,
                          startDate: day(2026, 1, 1))
        )
        insertedRule.categoryID = newCategoryID
        insertedRule.accountID = UUID() // dangling — must restore as nil

        let document = BackupDocument(
            formatVersion: 3, exportedAt: .now, appVersion: "test",
            accounts: [BackupAccount(bank)],
            categories: [
                BackupCategory(food),
                BackupCategory(LedgerCategory(id: newCategoryID, name: "Mới", kind: .expense)),
            ],
            businesses: [], transactions: [],
            budgets: [updatedBudget, insertedBudget],
            recurringRules: [updatedRule, insertedRule]
        )

        let result = try BackupRestorer.restore(document, mode: .merge, into: context)

        #expect(result.inserted == 3) // new category + budget + rule
        #expect(result.updated == 4)  // account + category + budget + rule

        #expect(budget.monthlyLimit == 2_000_000)
        #expect(!budget.isActive)
        #expect(budget.note == "đổi")
        #expect(budget.category?.id == food.id)

        #expect(rule.title == "Gói mềm mới")
        #expect(rule.amount == 150_000)
        #expect(rule.frequencyRaw == "weekly")
        #expect(rule.maximumOccurrences == 8)
        #expect(rule.account?.id == bank.id)

        let budgets = try fetchAll(Budget.self, in: context)
        let rBudget = try #require(budgets.first { $0.id == newBudgetID })
        #expect(rBudget.monthlyLimit == 5_000_000)
        #expect(rBudget.category?.id == newCategoryID)

        let rules = try fetchAll(RecurringRule.self, in: context)
        let rRule = try #require(rules.first { $0.id == newRuleID })
        #expect(rRule.frequencyRaw == "yearly")
        #expect(rRule.category?.id == newCategoryID)
        #expect(rRule.account == nil)
    }

    /// The backup covers every model type in the schema — this fails the
    /// moment a new `@Model` lands in `AppSchema.allModels` without backup
    /// support, so one can never be forgotten.
    @Test func backupCoversEveryModelInTheSchema() {
        let schema = Set(AppSchema.allModels.map { ObjectIdentifier($0) })
        let covered = Set(BackupCoverage.coveredModels.map { ObjectIdentifier($0) })
        #expect(covered == schema)
    }

    // MARK: - Older files

    /// A v1 file has no `loanRateChanges` key at all — it still decodes and
    /// restores, with the rate-change list read as empty.
    @Test func version1FileStillDecodesAndRestores() throws {
        let context = try makeContext()
        let json = """
        {"formatVersion": 1,
         "exportedAt": "2026-11-01T00:00:00Z",
         "appVersion": "1.0",
         "accounts": [{
            "id": "5EED0000-0000-4000-8000-00000000AA01",
            "name": "Thẻ cũ", "kindRaw": "creditCard",
            "openingBalance": -1500000, "icon": "creditcard.fill",
            "colorHex": "FF9500", "note": "", "sortOrder": 0,
            "isArchived": false,
            "createdAt": "2026-01-01T00:00:00Z"}],
         "categories": [], "businesses": [], "transactions": []}
        """
        let document = try BackupCodec.decode(Data(json.utf8))
        #expect(document.formatVersion == 1)
        #expect(document.loanRateChanges.isEmpty)
        #expect(document.budgets.isEmpty)
        #expect(document.recurringRules.isEmpty)

        let result = try BackupRestorer.restore(document, mode: .merge, into: context)
        #expect(result.inserted == 1)
        let restored = try #require(
            try fetchAll(Account.self, in: context).first { $0.name == "Thẻ cũ" }
        )
        #expect(restored.kind == .creditCard)
        #expect(restored.openingBalance == -1_500_000)
    }

    /// A v2 file has `loanRateChanges` but no `budgets`/`recurringRules`
    /// keys — it still decodes and restores with both read as empty.
    @Test func version2FileStillDecodesAndRestores() throws {
        let context = try makeContext()
        let json = """
        {"formatVersion": 2,
         "exportedAt": "2026-11-10T00:00:00Z",
         "appVersion": "1.0",
         "accounts": [{
            "id": "5EED0000-0000-4000-8000-00000000BB01",
            "name": "Tiền mặt", "kindRaw": "cash",
            "openingBalance": 500000, "icon": "banknote.fill",
            "colorHex": "34C759", "note": "", "sortOrder": 0,
            "isArchived": false,
            "createdAt": "2026-01-01T00:00:00Z"}],
         "categories": [], "businesses": [], "transactions": [],
         "loanRateChanges": []}
        """
        let document = try BackupCodec.decode(Data(json.utf8))
        #expect(document.formatVersion == 2)
        #expect(document.budgets.isEmpty)
        #expect(document.recurringRules.isEmpty)

        let result = try BackupRestorer.restore(document, mode: .merge, into: context)
        #expect(result.inserted == 1)
        #expect(try fetchAll(Account.self, in: context).count == 1)
    }

    // MARK: - Account.business (formatVersion 4)

    /// A receivable account's business link exports as `businessID` and is
    /// re-linked to the restored business — including on a replace restore
    /// where the business row itself is reinserted.
    @Test func roundTripKeepsAccountBusiness() throws {
        let context = try makeContext()
        let business = Business(name: "Chạy quảng cáo thuê", sortOrder: 3)
        let client = Account(name: "Khách A", kind: .receivable)
        client.business = business
        let bank = Account(name: "Ngân hàng", kind: .bank)
        context.insert(business)
        context.insert(client)
        context.insert(bank)
        try context.save()

        let businessID = business.id, clientID = client.id, bankID = bank.id

        let data = try BackupCodec.encode(context: context)
        let document = try BackupCodec.decode(data)
        #expect(document.formatVersion == BackupCodec.formatVersion)
        #expect(document.accounts.first { $0.id == clientID }?.businessID == businessID)
        #expect(document.accounts.first { $0.id == bankID }?.businessID == nil)

        try BackupRestorer.restore(document, mode: .replace, into: context)

        let accounts = try fetchAll(Account.self, in: context)
        let rClient = try #require(accounts.first { $0.id == clientID })
        let rBank = try #require(accounts.first { $0.id == bankID })
        #expect(rClient.business?.id == businessID)
        #expect(rBank.business == nil)
        #expect(rClient.business?.accounts?.contains { $0.id == clientID } == true)
    }

    /// Merge re-links `business` onto an existing account too.
    @Test func mergeUpsertsAccountBusiness() throws {
        let context = try makeContext()
        let business = Business(name: "Làm web")
        let client = Account(name: "Khách B", kind: .receivable)
        context.insert(business)
        context.insert(client)
        try context.save()

        var dto = BackupAccount(client)
        dto.businessID = business.id
        let document = BackupDocument(
            formatVersion: 4, exportedAt: .now, appVersion: "test",
            accounts: [dto, BackupAccount(Account(name: "Khách C", kind: .receivable))],
            categories: [],
            businesses: [BackupBusiness(business)],
            transactions: []
        )

        let result = try BackupRestorer.restore(document, mode: .merge, into: context)
        #expect(result.updated == 2)   // client + the re-applied business
        #expect(result.inserted == 1)  // the new receivable
        #expect(client.business?.id == business.id)
        let newClient = try #require(
            try fetchAll(Account.self, in: context).first { $0.name == "Khách C" }
        )
        #expect(newClient.business == nil)
    }

    /// A v3 account has no `businessID` key — it decodes as nil and the
    /// restored account keeps no business link.
    @Test func version3FileStillDecodesAndRestores() throws {
        let context = try makeContext()
        let json = """
        {"formatVersion": 3,
         "exportedAt": "2026-11-15T00:00:00Z",
         "appVersion": "1.0",
         "accounts": [{
            "id": "5EED0000-0000-4000-8000-00000000CC01",
            "name": "Khách cũ", "kindRaw": "receivable",
            "openingBalance": 800000, "icon": "person.badge.clock.fill",
            "colorHex": "0A84FF", "note": "", "sortOrder": 0,
            "isArchived": false,
            "createdAt": "2026-01-01T00:00:00Z"}],
         "categories": [], "businesses": [], "transactions": [],
         "loanRateChanges": [], "budgets": [], "recurringRules": []}
        """
        let document = try BackupCodec.decode(Data(json.utf8))
        #expect(document.formatVersion == 3)
        #expect(document.accounts.first?.businessID == nil)

        let result = try BackupRestorer.restore(document, mode: .merge, into: context)
        #expect(result.inserted == 1)
        let restored = try #require(
            try fetchAll(Account.self, in: context).first { $0.name == "Khách cũ" }
        )
        #expect(restored.kind == .receivable)
        #expect(restored.openingBalance == 800_000)
        #expect(restored.business == nil)
    }

    // MARK: - Rental units and leases (formatVersion 5)

    /// A serviced-apartment round trip: the unit's fields, the lease's
    /// fields, the unit→business and lease→unit links, and a rent
    /// collection's lease/period on its transaction all come back.
    @Test func replaceRestoreRoundTripsRentals() throws {
        let context = try makeContext()
        let apartment = Business(name: "Căn hộ dịch vụ", sortOrder: 2)
        let bank = Account(name: "Ngân hàng", kind: .bank, openingBalance: 0)
        let unit = RentalUnit(
            name: "Phòng 101", listPrice: 5_000_000, note: "Tầng 1",
            sortOrder: 4, business: apartment
        )
        unit.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let archived = RentalUnit(
            name: "Phòng cũ", listPrice: 3_000_000,
            sortOrder: 9, isArchived: true
        )
        let lease = RentalLease(
            tenantName: "Nguyễn Văn A", tenantPhone: "090 123 4567",
            startDate: day(2026, 1, 15), endDate: day(2026, 12, 31),
            monthlyRent: 5_000_000, deposit: 5_000_000,
            paymentDay: 31, isActive: true,
            note: "Trả đầu tháng", unit: unit
        )
        lease.createdAt = Date(timeIntervalSince1970: 1_700_000_100)
        let rentRow = LedgerTransaction(
            kind: .income, amount: 5_000_000,
            date: day(2026, 11, 5), note: "Tiền Phòng 101 tháng 11/2026",
            account: bank, business: apartment,
            rentalLease: lease, rentalPeriod: day(2026, 11, 1)
        )
        let extraRow = LedgerTransaction(
            kind: .income, amount: 700_000,
            date: day(2026, 11, 5), note: "Điện, nước",
            account: bank, rentalLease: lease, rentalPeriod: nil
        )
        context.insert(apartment)
        context.insert(bank)
        for room in [unit, archived] { context.insert(room) }
        context.insert(lease)
        for row in [rentRow, extraRow] { context.insert(row) }
        try context.save()

        let apartmentID = apartment.id, bankID = bank.id
        let unitID = unit.id, archivedID = archived.id, leaseID = lease.id
        let rentID = rentRow.id, extraID = extraRow.id

        let data = try BackupCodec.encode(
            context: context, exportedAt: Date(timeIntervalSince1970: 1_763_791_500)
        )
        let document = try BackupCodec.decode(data)
        #expect(document.formatVersion == BackupCodec.formatVersion)
        #expect(document.rentalUnits.count == 2)
        #expect(document.rentalLeases.count == 1)
        #expect(document.rentalUnits.first { $0.id == unitID }?.businessID == apartmentID)
        #expect(document.rentalLeases.first { $0.id == leaseID }?.unitID == unitID)
        #expect(document.transactions.first { $0.id == rentID }?.rentalLeaseID == leaseID)
        #expect(document.transactions.first { $0.id == rentID }?.rentalPeriod == day(2026, 11, 1))

        let result = try BackupRestorer.restore(document, mode: .replace, into: context)
        #expect(result.inserted == 2 + 1 + 1 + 1 + 2) // units+lease+account+business+transactions

        let units = try fetchAll(RentalUnit.self, in: context)
        #expect(units.count == 2)
        let rUnit = try #require(units.first { $0.id == unitID })
        #expect(rUnit.name == "Phòng 101")
        #expect(rUnit.listPrice == 5_000_000)
        #expect(rUnit.note == "Tầng 1")
        #expect(rUnit.sortOrder == 4)
        #expect(!rUnit.isArchived)
        #expect(rUnit.createdAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(rUnit.business?.id == apartmentID)
        let rArchived = try #require(units.first { $0.id == archivedID })
        #expect(rArchived.isArchived)
        #expect(rArchived.business == nil)

        let leases = try fetchAll(RentalLease.self, in: context)
        let rLease = try #require(leases.first { $0.id == leaseID })
        #expect(leases.count == 1)
        #expect(rLease.tenantName == "Nguyễn Văn A")
        #expect(rLease.tenantPhone == "090 123 4567")
        #expect(rLease.startDate == day(2026, 1, 15))
        #expect(rLease.endDate == day(2026, 12, 31))
        #expect(rLease.monthlyRent == 5_000_000)
        #expect(rLease.deposit == 5_000_000)
        #expect(rLease.paymentDay == 31)
        #expect(rLease.isActive)
        #expect(rLease.note == "Trả đầu tháng")
        #expect(rLease.createdAt == Date(timeIntervalSince1970: 1_700_000_100))
        #expect(rLease.unit?.id == unitID)
        // The inverse relationship was re-linked too.
        #expect(rUnit.leases?.contains { $0.id == leaseID } == true)

        let transactions = try fetchAll(LedgerTransaction.self, in: context)
        let rRent = try #require(transactions.first { $0.id == rentID })
        #expect(rRent.rentalLease?.id == leaseID)
        #expect(rRent.rentalPeriod == day(2026, 11, 1))
        #expect(rRent.business?.id == apartmentID)
        #expect(rRent.account?.id == bankID)
        let rExtra = try #require(transactions.first { $0.id == extraID })
        #expect(rExtra.rentalLease?.id == leaseID)
        #expect(rExtra.rentalPeriod == nil)
        #expect(rLease.payments?.count == 2)
    }

    /// Merge upserts both rental models: an existing unit/lease is updated
    /// in place, new ones insert, and a lease pointing at a unit the file
    /// does not contain relinks to the restored copy — a dangling unit id
    /// decodes to nil.
    @Test func mergeUpsertsRentalsAndRelinks() throws {
        let context = try makeContext()
        let apartment = Business(name: "Căn hộ dịch vụ")
        let unit = RentalUnit(name: "Phòng 101", listPrice: 4_000_000, business: apartment)
        let lease = RentalLease(
            tenantName: "Thuê cũ", startDate: day(2026, 1, 1),
            monthlyRent: 4_000_000, paymentDay: 5, unit: unit
        )
        context.insert(apartment)
        context.insert(unit)
        context.insert(lease)
        try context.save()

        let newUnitID = UUID()
        let newLeaseID = UUID()

        var updatedUnit = BackupRentalUnit(unit)
        updatedUnit.name = "Phòng 101 đổi tên"
        updatedUnit.listPrice = 5_000_000

        var updatedLease = BackupRentalLease(lease)
        updatedLease.tenantName = "Thuê mới"
        updatedLease.monthlyRent = 5_000_000
        updatedLease.isActive = false
        updatedLease.endDate = day(2026, 6, 30)

        var insertedLease = BackupRentalLease(
            RentalLease(id: newLeaseID, tenantName: "Thuê khác",
                        startDate: day(2026, 7, 1), monthlyRent: 6_000_000)
        )
        insertedLease.unitID = newUnitID
        var danglingLease = BackupRentalLease(
            RentalLease(tenantName: "Mồ côi", startDate: day(2026, 1, 1))
        )
        danglingLease.unitID = UUID() // not in the file — restores as nil

        // Built detached on purpose: assigning a live business while the
        // model is constructed would register it in the context and the
        // restore would read it as "existing" rather than "inserted".
        var newUnitDTO = BackupRentalUnit(RentalUnit(id: newUnitID, name: "Phòng 202"))
        newUnitDTO.businessID = apartment.id

        let document = BackupDocument(
            formatVersion: 5, exportedAt: .now, appVersion: "test",
            accounts: [], categories: [],
            businesses: [BackupBusiness(apartment)],
            transactions: [],
            rentalUnits: [updatedUnit, newUnitDTO],
            rentalLeases: [updatedLease, insertedLease, danglingLease]
        )

        let result = try BackupRestorer.restore(document, mode: .merge, into: context)
        #expect(result.updated == 3)   // business + unit + lease
        #expect(result.inserted == 3)  // new unit + two new leases

        #expect(unit.name == "Phòng 101 đổi tên")
        #expect(unit.listPrice == 5_000_000)
        #expect(unit.business?.id == apartment.id)
        #expect(lease.tenantName == "Thuê mới")
        #expect(lease.monthlyRent == 5_000_000)
        #expect(!lease.isActive)
        #expect(lease.endDate == day(2026, 6, 30))
        #expect(lease.unit?.id == unit.id)

        let units = try fetchAll(RentalUnit.self, in: context)
        #expect(units.count == 2)
        let newUnit = try #require(units.first { $0.id == newUnitID })
        #expect(newUnit.name == "Phòng 202")
        #expect(newUnit.business?.id == apartment.id)

        let leases = try fetchAll(RentalLease.self, in: context)
        #expect(leases.count == 3)
        #expect(try #require(leases.first { $0.id == newLeaseID }).unit?.id == newUnitID)
        #expect(try #require(leases.first { $0.tenantName == "Mồ côi" }).unit == nil)
    }

    /// A v4 file has no `rentalUnits`/`rentalLeases` keys and transactions
    /// without the rental fields — it still decodes and restores, with
    /// every rental value read as empty or nil.
    @Test func version4FileStillDecodesAndRestores() throws {
        let context = try makeContext()
        let json = """
        {"formatVersion": 4,
         "exportedAt": "2026-11-20T00:00:00Z",
         "appVersion": "1.0",
         "accounts": [{
            "id": "5EED0000-0000-4000-8000-00000000DD01",
            "name": "Tiền mặt", "kindRaw": "cash",
            "openingBalance": 0, "icon": "banknote.fill",
            "colorHex": "34C759", "note": "", "sortOrder": 0,
            "isArchived": false, "businessID": null,
            "createdAt": "2026-01-01T00:00:00Z"}],
         "categories": [], "businesses": [],
         "transactions": [{
            "id": "5EED0000-0000-4000-8000-00000000DD02",
            "kindRaw": "income", "amount": 5000000,
            "date": "2026-11-05T00:00:00Z", "note": "Thu nhập cũ",
            "accountID": "5EED0000-0000-4000-8000-00000000DD01",
            "needsReview": false,
            "createdAt": "2026-11-05T00:00:00Z",
            "updatedAt": "2026-11-05T00:00:00Z"}],
         "loanRateChanges": [], "budgets": [], "recurringRules": []}
        """
        let document = try BackupCodec.decode(Data(json.utf8))
        #expect(document.formatVersion == 4)
        #expect(document.rentalUnits.isEmpty)
        #expect(document.rentalLeases.isEmpty)
        #expect(document.transactions.first?.rentalLeaseID == nil)
        #expect(document.transactions.first?.rentalPeriod == nil)

        let result = try BackupRestorer.restore(document, mode: .merge, into: context)
        #expect(result.inserted == 2)
        let restored = try #require(
            try fetchAll(LedgerTransaction.self, in: context).first
        )
        #expect(restored.rentalLease == nil)
        #expect(restored.rentalPeriod == nil)
        #expect(restored.account?.name == "Tiền mặt")
    }

    // MARK: - Rejected files

    @Test func decodeRejectsNewerFormatVersion() throws {
        let json = """
        {"formatVersion": 6, "exportedAt": "2026-11-22T07:05:00Z",
         "appVersion": "9", "accounts": [], "categories": [],
         "businesses": [], "transactions": [], "loanRateChanges": []}
        """
        #expect(throws: BackupError.unsupportedVersion(found: 6)) {
            _ = try BackupCodec.decode(Data(json.utf8))
        }
    }

    @Test func malformedBackupsAreRejectedAndChangeNothing() throws {
        let context = try makeContext()
        try SeedData.seedIfNeeded(context: context)
        let accountCount = try fetchAll(Account.self, in: context).count
        let transactionCount = try fetchAll(LedgerTransaction.self, in: context).count

        for bad in [
            Data("not a backup".utf8),
            Data("{}".utf8),
            Data("{\"formatVersion\":\"hai\"}".utf8),
        ] {
            #expect(throws: BackupError.malformed) {
                _ = try BackupCodec.decode(bad)
            }
        }

        #expect(try fetchAll(Account.self, in: context).count == accountCount)
        #expect(try fetchAll(LedgerTransaction.self, in: context).count == transactionCount)
    }

    @Test func restoreRefusesNewerDocumentBeforeTouchingData() throws {
        let context = try makeContext()
        try SeedData.seedIfNeeded(context: context)
        let future = BackupDocument(
            formatVersion: 6, exportedAt: .now, appVersion: "x",
            accounts: [], categories: [], businesses: [], transactions: []
        )
        #expect(throws: BackupError.unsupportedVersion(found: 6)) {
            _ = try BackupRestorer.restore(future, mode: .replace, into: context)
        }
        // Even in replace mode nothing was deleted or inserted.
        #expect(try fetchAll(Account.self, in: context).count == 1)
        #expect(try fetchAll(LedgerCategory.self, in: context).count == 21)
    }

    // MARK: - CSV

    private func csvRow(
        _ date: Date, kindRaw: String = "expense",
        note: String = "", accountName: String = "Tiền mặt"
    ) -> BackupCSVRow {
        BackupCSVRow(
            date: date, kindRaw: kindRaw, amount: 1_000,
            accountName: accountName, toAccountName: "",
            categoryName: "", businessName: "", note: note
        )
    }

    @Test func csvRowFlattensTransactionRelationships() {
        let account = Account(name: "Ngân hàng", kind: .bank)
        let card = Account(name: "Thẻ tín dụng", kind: .creditCard)
        let food = LedgerCategory(name: "Ăn uống", kind: .expense)
        let web = Business(name: "Làm web")
        let transfer = LedgerTransaction(
            kind: .transfer, amount: 500_000, note: "trả thẻ",
            account: account, toAccount: card, category: food, business: web
        )
        let row = BackupCSVRow(transfer)
        #expect(row.accountName == "Ngân hàng")
        #expect(row.toAccountName == "Thẻ tín dụng")
        #expect(row.categoryName == "Ăn uống")
        #expect(row.businessName == "Làm web")

        let text = BackupCSV.string(rows: [row])
        #expect(text.contains(",Chuyển khoản,500000,"))
    }

    @Test func csvWritesBOMHeaderAndEscapesFields() throws {
        let row = BackupCSVRow(
            date: day(2026, 11, 22, 14, 5),
            kindRaw: "expense",
            amount: 1_250_000,
            accountName: "Tiền mặt, két sắt",
            toAccountName: "",
            categoryName: "Ăn uống",
            businessName: "Web \"xịn\"",
            note: "dòng một\ndòng hai"
        )
        let data = BackupCSV.data(rows: [row])

        // UTF-8 BOM so Excel opens the file with the right encoding.
        #expect(data.starts(with: [0xEF, 0xBB, 0xBF]))

        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasPrefix(
            "\u{FEFF}Ngày,Loại,Số tiền,Tài khoản,Tài khoản đích,Danh mục,Doanh nghiệp,Ghi chú"
        ))
        #expect(text.contains("2026-11-22 14:05,Chi,1250000,"))
        // Comma, quote and newline all trigger quoting; quotes are doubled.
        #expect(text.contains("\"Tiền mặt, két sắt\""))
        #expect(text.contains("\"Web \"\"xịn\"\"\""))
        #expect(text.contains("\"dòng một\ndòng hai\""))
        #expect(text.hasSuffix("\r\n"))
    }

    @Test func csvFiltersRowsByDateRangeAndSorts() throws {
        let rows = [
            csvRow(day(2026, 11, 25, 0, 1), note: "ngoài-sau"),
            csvRow(day(2026, 11, 20, 23, 59), note: "trong-2"),
            csvRow(day(2026, 11, 10, 9), note: "ngoài-trước"),
            csvRow(day(2026, 11, 15, 12), note: "trong-1"),
        ]
        let text = BackupCSV.string(
            rows: rows,
            from: day(2026, 11, 12),
            to: day(2026, 11, 20, 23, 59)
        )
        #expect(text.contains("trong-1"))
        #expect(text.contains("trong-2"))
        #expect(!text.contains("ngoài-trước"))
        #expect(!text.contains("ngoài-sau"))

        // Header + exactly the two in-range rows.
        #expect(text.components(separatedBy: "\r\n").count == 4)

        // Rows were passed out of order; output is sorted by date.
        let first = try #require(text.range(of: "trong-1")).lowerBound
        let second = try #require(text.range(of: "trong-2")).lowerBound
        #expect(first < second)
    }

    // MARK: - Small helpers

    @Test func fileStampFormatsForFileNames() {
        #expect(BackupCodec.fileStamp(day(2026, 11, 22, 14, 5)) == "20261122-1405")
    }

    @Test func reminderIsDueWhenNeverExportedOrOlderThanAWeek() {
        let now = Date.now
        #expect(BackupReminder.isDue(lastExport: nil, now: now))
        #expect(BackupReminder.isDue(
            lastExport: now.addingTimeInterval(-8 * 86_400), now: now
        ))
        #expect(!BackupReminder.isDue(
            lastExport: now.addingTimeInterval(-6 * 86_400), now: now
        ))
    }
}
