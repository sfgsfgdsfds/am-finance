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

        let result = try BackupRestorer.restore(document, mode: .merge, into: context)
        #expect(result.inserted == 1)
        let restored = try #require(
            try fetchAll(Account.self, in: context).first { $0.name == "Thẻ cũ" }
        )
        #expect(restored.kind == .creditCard)
        #expect(restored.openingBalance == -1_500_000)
    }

    // MARK: - Rejected files

    @Test func decodeRejectsNewerFormatVersion() throws {
        let json = """
        {"formatVersion": 3, "exportedAt": "2026-11-22T07:05:00Z",
         "appVersion": "9", "accounts": [], "categories": [],
         "businesses": [], "transactions": [], "loanRateChanges": []}
        """
        #expect(throws: BackupError.unsupportedVersion(found: 3)) {
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
            formatVersion: 3, exportedAt: .now, appVersion: "x",
            accounts: [], categories: [], businesses: [], transactions: []
        )
        #expect(throws: BackupError.unsupportedVersion(found: 3)) {
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
