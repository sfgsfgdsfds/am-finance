import Testing
import SwiftData
import Foundation
import FinanceCore
@testable import AMFinance

@MainActor
struct BillSplitTests {

    private let calendar = AppCalendar.vietnam

    private func makeContext() throws -> ModelContext {
        ModelContext(try AppModelContainer.make(inMemory: true))
    }

    private func day(
        _ year: Int, _ month: Int, _ dayOfMonth: Int, _ hour: Int = 12
    ) -> Date {
        calendar.date(from: DateComponents(
            year: year, month: month, day: dayOfMonth, hour: hour
        ))!
    }

    private func fetchAll<T: PersistentModel>(
        _ type: T.Type, in context: ModelContext
    ) throws -> [T] {
        try context.fetch(FetchDescriptor<T>())
    }

    /// A wallet-synced expense row — the unclassified import shape.
    private func makeSyncedExpense(
        in context: ModelContext, amount: Int64, payer: Account
    ) -> LedgerTransaction {
        let row = LedgerTransaction(
            kind: .expense, amount: amount, date: day(2026, 11, 20),
            note: "GRAB FOOD", account: payer, needsReview: true)
        row.externalSource = WalletSyncEngine.externalSource
        row.externalID = "w-123"
        row.updatedAt = day(2026, 11, 20)
        context.insert(row)
        return row
    }

    // MARK: - New bill

    /// The canonical bill: 1,2 triệu trả bằng tiền mặt, chia đều 4
    /// người — phần của mình 300k chi, ba bạn mỗi người một khoản ứng
    /// 300k; tiền mặt trừ đúng 1.200.000.
    @Test func newBillPostsOwnShareExpensePlusThreeAdvances() throws {
        let context = try makeContext()
        let cash = Account(name: "Tiền mặt", kind: .cash, openingBalance: 2_000_000)
        let food = LedgerCategory(name: "Ăn uống", kind: .expense)
        context.insert(cash)
        context.insert(food)
        try context.save()

        let result = try BillSplitService().splitNewBill(
            total: 1_200_000, payer: cash, date: day(2026, 11, 21),
            category: food, note: "  Ăn trưa nhóm  ",
            participants: [
                .newPerson(" An "), .newPerson("Bình"), .newPerson("Chi")],
            in: context)

        #expect(result.expense.kind == .expense)
        #expect(result.expense.amount == 300_000)
        #expect(result.expense.account?.id == cash.id)
        #expect(result.expense.category?.id == food.id)
        #expect(result.expense.note == "Ăn trưa nhóm")
        #expect(result.expense.date == day(2026, 11, 21))
        #expect(result.expense.business == nil)
        #expect(!result.expense.needsReview)

        #expect(result.advances.count == 3)
        #expect(result.advances.allSatisfy {
            $0.kind == .transfer && $0.amount == 300_000
                && $0.account?.id == cash.id && $0.date == day(2026, 11, 21)
                && $0.note == "Ăn trưa nhóm"
                && $0.category == nil && $0.business == nil
                && $0.externalSource == nil && $0.externalID == nil
        })

        #expect(result.createdAccounts.map(\.name) == ["An", "Bình", "Chi"])
        #expect(result.createdAccounts.allSatisfy {
            $0.kind == .receivable && $0.business == nil && !$0.isArchived
        })
        #expect(result.receivables.map(\.id)
            == result.createdAccounts.map(\.id))
        #expect(Set(result.advances.compactMap { $0.toAccount?.id })
            == Set(result.receivables.map(\.id)))

        // Payer debited exactly the bill total; each friend owes a share.
        #expect(cash.balance == 800_000)
        #expect(result.receivables.allSatisfy { $0.balance == 300_000 })
        #expect(try fetchAll(LedgerTransaction.self, in: context).count == 4)
        #expect(result.plan.shares
            == [300_000, 300_000, 300_000, 300_000])
    }

    /// A typed name that folds onto an existing personal receivable is a
    /// validation error — the user must pick that client explicitly —
    /// never a silent re-use. Nothing is written.
    @Test func newPersonNameMatchingExistingReceivableFails() throws {
        let context = try makeContext()
        let cash = Account(name: "Tiền mặt", kind: .cash, openingBalance: 2_000_000)
        let an = Account(name: "An", kind: .receivable)
        let business = Business(name: "Làm web")
        let businessClient = Account(name: "Bình", kind: .receivable)
        businessClient.business = business
        context.insert(cash)
        context.insert(an)
        context.insert(business)
        context.insert(businessClient)
        try context.save()

        // "an" folds onto the existing personal client — refused, and
        // the second participant is never resolved either.
        #expect(throws: BillSplitError.participantNameMatchesExisting) {
            _ = try BillSplitService().splitNewBill(
                total: 600_000, payer: cash, date: day(2026, 11, 21),
                category: nil, note: "Cà phê",
                participants: [.newPerson("  an  "), .newPerson("bình")],
                in: context)
        }
        #expect(try fetchAll(LedgerTransaction.self, in: context).isEmpty)
        #expect(try fetchAll(Account.self, in: context).count == 3)
        #expect(an.balance == 0)
        #expect(!context.hasChanges)
    }

    /// A name that only collides with a *business* client does not trip
    /// the personal-receivable check: the split needs a personal
    /// receivable, so a new account is the right identity.
    @Test func newPersonNameCollidingWithBusinessClientCreatesPersonal() throws {
        let context = try makeContext()
        let cash = Account(name: "Tiền mặt", kind: .cash, openingBalance: 2_000_000)
        let business = Business(name: "Làm web")
        let businessClient = Account(name: "Bình", kind: .receivable)
        businessClient.business = business
        context.insert(cash)
        context.insert(business)
        context.insert(businessClient)
        try context.save()

        let result = try BillSplitService().splitNewBill(
            total: 600_000, payer: cash, date: day(2026, 11, 21),
            category: nil, note: "Cà phê",
            participants: [.newPerson("bình"), .newPerson("Chi")],
            in: context)

        // "bình" only collided with a business client — a new personal
        // receivable was created instead of touching it.
        #expect(result.createdAccounts.map(\.name) == ["bình", "Chi"])
        #expect(result.createdAccounts.allSatisfy { $0.business == nil })
        #expect(result.receivables.map(\.id)
            == result.createdAccounts.map(\.id))
        #expect(result.createdAccounts[0].balance == 200_000)
        #expect(businessClient.balance == 0)
    }

    /// Two participant slots resolving to one account are rejected —
    /// distinct receivables are required and nothing is written.
    @Test func newBillRejectsDuplicateParticipants() throws {
        let context = try makeContext()
        let cash = Account(name: "Tiền mặt", kind: .cash)
        let an = Account(name: "An", kind: .receivable)
        context.insert(cash)
        context.insert(an)
        try context.save()
        let service = BillSplitService()

        // Two spellings of the same new name collapse to one account.
        #expect(throws: BillSplitError.duplicateParticipant) {
            _ = try service.splitNewBill(
                total: 600_000, payer: cash, date: .now,
                category: nil, note: "",
                participants: [.newPerson("Thu"), .newPerson("  thu ")],
                in: context)
        }
        // The same client picked twice collides too.
        #expect(throws: BillSplitError.duplicateParticipant) {
            _ = try service.splitNewBill(
                total: 600_000, payer: cash, date: .now,
                category: nil, note: "",
                participants: [.existing(an), .existing(an)],
                in: context)
        }
        // An existing client and a same-named new person: the typed name
        // is rejected up front — explicit selection is required.
        #expect(throws: BillSplitError.participantNameMatchesExisting) {
            _ = try service.splitNewBill(
                total: 600_000, payer: cash, date: .now,
                category: nil, note: "",
                participants: [.existing(an), .newPerson("an")],
                in: context)
        }
        #expect(try fetchAll(LedgerTransaction.self, in: context).isEmpty)
        #expect(!context.hasChanges)
    }

    @Test func newBillRejectsInvalidPayersAndParticipants() throws {
        let context = try makeContext()
        let loan = Account(name: "Vay", kind: .loan)
        let receivablePayer = Account(name: "Khách X", kind: .receivable)
        let archived = Account(name: "Cũ", kind: .bank, isArchived: true)
        let business = Business(name: "Chạy ads")
        let businessClient = Account(name: "Khách Y", kind: .receivable)
        businessClient.business = business
        let cashPayer = Account(name: "Tiền mặt", kind: .cash)
        context.insert(business)
        for account in [loan, receivablePayer, archived, businessClient, cashPayer] {
            context.insert(account)
        }
        try context.save()
        let service = BillSplitService()

        // Non-advance-capable payers: loan, receivable, archived bank.
        for payer in [loan, receivablePayer, archived] {
            #expect(throws: BillSplitError.invalidPayer) {
                _ = try service.splitNewBill(
                    total: 400_000, payer: payer, date: .now,
                    category: nil, note: "",
                    participants: [.newPerson("An")], in: context)
            }
        }
        // A business client or a plain cash account is not a personal
        // receivable.
        for bad in [businessClient, cashPayer] {
            #expect(throws: BillSplitError.invalidParticipant) {
                _ = try service.splitNewBill(
                    total: 400_000, payer: cashPayer, date: .now,
                    category: nil, note: "",
                    participants: [.existing(bad)], in: context)
            }
        }
        // Nothing ever landed.
        #expect(try fetchAll(LedgerTransaction.self, in: context).isEmpty)
        #expect(!context.hasChanges)
    }

    /// A credit card is a legitimate payer — the bill raises card debt
    /// by exactly the total.
    @Test func newBillAcceptsCreditCardPayer() throws {
        let context = try makeContext()
        let card = Account(
            name: "Thẻ Visa", kind: .creditCard, openingBalance: -500_000)
        context.insert(card)
        try context.save()

        let result = try BillSplitService().splitNewBill(
            total: 800_000, payer: card, date: .now, category: nil,
            note: "Đi chơi",
            participants: [
                .newPerson("An"), .newPerson("Bình"), .newPerson("Chi")],
            in: context)
        #expect(card.balance == -1_300_000)
        #expect(result.receivables.allSatisfy { $0.balance == 200_000 })
    }

    /// Remainder đồng land one at a time in display order, self first.
    @Test func newBillDistributesRemainderFromSelf() throws {
        let context = try makeContext()
        let cash = Account(name: "Tiền mặt", kind: .cash)
        context.insert(cash)
        try context.save()
        let result = try BillSplitService().splitNewBill(
            total: 1_000_003, payer: cash, date: .now, category: nil,
            note: "",
            participants: [
                .newPerson("An"), .newPerson("Bình"), .newPerson("Chi")],
            in: context)
        #expect(result.expense.amount == 250_001)
        #expect(result.advances.map(\.amount) == [250_001, 250_001, 250_000])
        #expect(cash.balance == -1_000_003)
    }

    /// A split with nobody to split with, or a total too small for the
    /// party, fails validation before any write.
    @Test func newBillRejectsBadTotalsAndPartySizes() throws {
        let context = try makeContext()
        let cash = Account(name: "Tiền mặt", kind: .cash)
        context.insert(cash)
        try context.save()
        let service = BillSplitService()

        #expect(throws: BillSplitError.tooFewParticipants) {
            _ = try service.splitNewBill(
                total: 500_000, payer: cash, date: .now, category: nil,
                note: "", participants: [], in: context)
        }
        #expect(throws: BillSplitError.shareWouldBeZero) {
            _ = try service.splitNewBill(
                total: 3, payer: cash, date: .now, category: nil,
                note: "",
                participants: [
                    .newPerson("A"), .newPerson("B"), .newPerson("C")],
                in: context)
        }
        #expect(throws: BillSplitError.nonPositiveTotal) {
            _ = try service.splitNewBill(
                total: 0, payer: cash, date: .now, category: nil,
                note: "", participants: [.newPerson("A")], in: context)
        }
        #expect(throws: BillSplitError.emptyParticipantName) {
            _ = try service.splitNewBill(
                total: 500_000, payer: cash, date: .now, category: nil,
                note: "", participants: [.newPerson("   ")], in: context)
        }
        #expect(try fetchAll(LedgerTransaction.self, in: context).isEmpty)
        #expect(!context.hasChanges)
    }

    // MARK: - Existing expense

    /// An unclassified wallet import splits in place: same row id, same
    /// external identity, same date and payer — only the amount shrinks,
    /// a category lands and the review flag clears.
    @Test func splitExistingShrinksSyncedExpenseKeepingProvenance() throws {
        let context = try makeContext()
        let bank = Account(
            name: "VPBank *1234", kind: .bank, openingBalance: 5_000_000)
        let food = LedgerCategory(name: "Ăn uống", kind: .expense)
        context.insert(bank)
        context.insert(food)
        let row = makeSyncedExpense(in: context, amount: 1_200_000, payer: bank)
        try context.save()
        let snapshot = BillSplitOriginal(of: row)

        let result = try BillSplitService().splitExistingExpense(
            row, expected: snapshot, category: food,
            participants: [
                .newPerson("An"), .newPerson("Bình"), .newPerson("Chi")],
            in: context)

        // The very same row — the wallet dedupe identity must survive.
        #expect(result.expense === row)
        #expect(row.id == snapshot.id)
        #expect(row.amount == 300_000)
        #expect(row.kind == .expense)
        #expect(row.externalSource == WalletSyncEngine.externalSource)
        #expect(row.externalID == "w-123")
        #expect(row.date == day(2026, 11, 20))
        #expect(row.account?.id == bank.id)
        #expect(row.note == "GRAB FOOD")
        #expect(row.category?.id == food.id)
        #expect(!row.needsReview)
        #expect(row.updatedAt > snapshot.updatedAt)

        // Payer debited exactly the original total across the 4 rows.
        #expect(bank.balance == 5_000_000 - 1_200_000)
        #expect(result.advances.allSatisfy {
            $0.kind == .transfer && $0.amount == 300_000
                && $0.account?.id == bank.id && $0.date == row.date
                && $0.externalID == nil && $0.externalSource == nil
        })
        #expect(try fetchAll(LedgerTransaction.self, in: context).count == 4)
    }

    /// A snapshot captured before another edit rejects the confirm.
    @Test func splitExistingRejectsStaleConfirmation() throws {
        let context = try makeContext()
        let cash = Account(name: "Tiền mặt", kind: .cash)
        context.insert(cash)
        let row = makeSyncedExpense(in: context, amount: 1_200_000, payer: cash)
        try context.save()
        let snapshot = BillSplitOriginal(of: row)

        // Somebody edits the row after the sheet was shown.
        row.note = "Đã sửa"
        row.updatedAt = .now
        try context.save()

        #expect(throws: BillSplitError.staleTransaction) {
            _ = try BillSplitService().splitExistingExpense(
                row, expected: snapshot, category: nil,
                participants: [.newPerson("An")], in: context)
        }
        // Nothing mutated, nothing inserted.
        #expect(row.amount == 1_200_000)
        #expect(row.needsReview)
        #expect(try fetchAll(LedgerTransaction.self, in: context).count == 1)
        #expect(!context.hasChanges)
    }

    /// Submitting the same confirmation a second time must not split
    /// again — the row already moved.
    @Test func splitExistingRejectsRepeatedSubmission() throws {
        let context = try makeContext()
        let cash = Account(name: "Tiền mặt", kind: .cash, openingBalance: 2_000_000)
        context.insert(cash)
        let row = LedgerTransaction(
            kind: .expense, amount: 600_000, date: day(2026, 11, 20),
            note: "Trà sữa", account: cash)
        context.insert(row)
        try context.save()
        let snapshot = BillSplitOriginal(of: row)
        let service = BillSplitService()

        _ = try service.splitExistingExpense(
            row, expected: snapshot, category: nil,
            participants: [.newPerson("An")], in: context)
        #expect(row.amount == 300_000)

        #expect(throws: BillSplitError.staleTransaction) {
            _ = try service.splitExistingExpense(
                row, expected: snapshot, category: nil,
                participants: [.newPerson("An")], in: context)
        }
        // Still exactly the first split's rows.
        #expect(try fetchAll(LedgerTransaction.self, in: context).count == 2)
        #expect(cash.balance == 2_000_000 - 600_000)
    }

    /// Business rows, rent-linked rows, transfers and expenses on
    /// non-advance accounts all belong to their own features — never
    /// mutated here.
    @Test func splitExistingRejectsIneligibleRows() throws {
        let context = try makeContext()
        let cash = Account(name: "Tiền mặt", kind: .cash)
        let business = Business(name: "Chạy ads")
        let client = Account(name: "Khách", kind: .receivable)
        context.insert(cash)
        context.insert(business)
        context.insert(client)
        let service = BillSplitService()

        func row(
            kind: TransactionKind = .expense,
            account: Account? = nil,
            mutate: (LedgerTransaction) -> Void = { _ in }
        ) throws -> LedgerTransaction {
            let t = LedgerTransaction(
                kind: kind, amount: 600_000, account: account ?? cash)
            mutate(t)
            context.insert(t)
            try context.save()
            return t
        }

        let businessRow = try row { $0.business = business }
        let rentRow = try row { $0.rentalPeriod = day(2026, 11, 1) }
        let transferRow = try row(kind: .transfer) { $0.toAccount = client }
        let receivableSource = try row(account: client)
        let destinationSet = try row { $0.toAccount = client }
        for bad in [
            businessRow, rentRow, transferRow, receivableSource, destinationSet,
        ] {
            let snapshot = BillSplitOriginal(of: bad)
            #expect(throws: BillSplitError.transactionNotEligible) {
                _ = try service.splitExistingExpense(
                    bad, expected: snapshot, category: nil,
                    participants: [.newPerson("An")], in: context)
            }
        }
        #expect(try fetchAll(LedgerTransaction.self, in: context).count == 5)
        #expect(businessRow.amount == 600_000)
        #expect(!context.hasChanges)
    }

    /// A supplied category must be a live expense category.
    @Test func splitExistingRejectsBadCategory() throws {
        let context = try makeContext()
        let cash = Account(name: "Tiền mặt", kind: .cash)
        let income = LedgerCategory(name: "Thu khác", kind: .income)
        let archived = LedgerCategory(
            name: "Cũ", kind: .expense, isArchived: true)
        context.insert(cash)
        context.insert(income)
        context.insert(archived)
        let row = LedgerTransaction(
            kind: .expense, amount: 600_000, account: cash)
        context.insert(row)
        try context.save()
        let snapshot = BillSplitOriginal(of: row)
        let service = BillSplitService()

        for bad in [income, archived] {
            #expect(throws: BillSplitError.invalidCategory) {
                _ = try service.splitExistingExpense(
                    row, expected: snapshot, category: bad,
                    participants: [.newPerson("An")], in: context)
            }
        }
        #expect(row.amount == 600_000)
        #expect(try fetchAll(LedgerTransaction.self, in: context).count == 1)
        #expect(!context.hasChanges)
    }

    /// With no category supplied the row keeps its own — and keeps the
    /// review flag too: a split is not a classification, so a still-
    /// uncategorized row stays "Chờ phân loại".
    @Test func splitExistingWithoutCategoryKeepsReviewFlag() throws {
        let context = try makeContext()
        let cash = Account(name: "Tiền mặt", kind: .cash)
        context.insert(cash)
        let row = makeSyncedExpense(in: context, amount: 600_000, payer: cash)
        try context.save()
        let snapshot = BillSplitOriginal(of: row)

        _ = try BillSplitService().splitExistingExpense(
            row, expected: snapshot, category: nil,
            participants: [.newPerson("An")], in: context)
        #expect(row.needsReview)
        #expect(row.category == nil)
        #expect(row.amount == 300_000)
    }

    // MARK: - Assign repayment

    /// A synced income becomes a `receivable -> bank` transfer in
    /// place: provenance, amount, date and note survive; the receiver's
    /// balance is unchanged; the receivable's outstanding drops.
    @Test func assignRepaymentConvertsSyncedIncomeInPlace() throws {
        let context = try makeContext()
        let bank = Account(
            name: "VPBank *1234", kind: .bank, openingBalance: 1_000_000)
        let cash = Account(name: "Tiền mặt", kind: .cash)
        let an = Account(name: "An", kind: .receivable)
        let misc = LedgerCategory(name: "Thu khác", kind: .income)
        for model in [bank, cash, an] { context.insert(model) }
        context.insert(misc)
        context.insert(ReceivableActions.advance(
            receivable: an, from: cash, amount: 900_000,
            date: day(2026, 11, 1), note: ""))
        let income = LedgerTransaction(
            kind: .income, amount: 600_000, date: day(2026, 11, 15),
            note: "AN CHUYEN", account: bank, category: misc,
            needsReview: true)
        income.externalSource = WalletSyncEngine.externalSource
        income.externalID = "w-99"
        income.updatedAt = day(2026, 11, 15)
        context.insert(income)
        try context.save()
        let bankBefore = bank.balance
        let snapshot = BillSplitOriginal(of: income)

        try BillSplitService().assignRepayment(
            income, expected: snapshot, to: an, in: context)

        #expect(income.kind == .transfer)
        #expect(income.account?.id == an.id)
        #expect(income.toAccount?.id == bank.id)
        #expect(income.amount == 600_000)
        #expect(income.date == day(2026, 11, 15))
        #expect(income.note == "AN CHUYEN")
        #expect(income.externalSource == WalletSyncEngine.externalSource)
        #expect(income.externalID == "w-99")
        #expect(income.category == nil)
        #expect(income.business == nil)
        #expect(!income.needsReview)
        #expect(income.updatedAt > snapshot.updatedAt)
        // +600k income became +600k transfer destination — same balance.
        #expect(bank.balance == bankBefore)
        #expect(ReceivableSnapshot.make(account: an).outstanding == 300_000)
        // Converted in place — no new row appeared.
        #expect(try fetchAll(LedgerTransaction.self, in: context).count == 2)
    }

    /// Two incomes assigned one after another: partial then final.
    @Test func assignRepaymentSettlesPartialThenFinal() throws {
        let context = try makeContext()
        let bank = Account(name: "Ngân hàng", kind: .bank)
        let cash = Account(name: "Tiền mặt", kind: .cash)
        let an = Account(name: "An", kind: .receivable)
        for model in [bank, cash, an] { context.insert(model) }
        context.insert(ReceivableActions.advance(
            receivable: an, from: cash, amount: 900_000,
            date: day(2026, 11, 1), note: ""))
        func income(_ amount: Int64, _ externalID: String) -> LedgerTransaction {
            let row = LedgerTransaction(
                kind: .income, amount: amount, date: day(2026, 11, 15),
                account: bank, needsReview: true)
            row.externalSource = WalletSyncEngine.externalSource
            row.externalID = externalID
            context.insert(row)
            return row
        }
        let first = income(500_000, "w-1")
        let second = income(400_000, "w-2")
        try context.save()
        let service = BillSplitService()

        try service.assignRepayment(
            first, expected: BillSplitOriginal(of: first), to: an,
            in: context)
        #expect(ReceivableSnapshot.make(account: an).outstanding == 400_000)

        try service.assignRepayment(
            second, expected: BillSplitOriginal(of: second), to: an,
            in: context)
        let snapshot = ReceivableSnapshot.make(account: an)
        #expect(snapshot.outstanding == 0)
        #expect(snapshot.isSettled)
        #expect(an.balance == 0)
    }

    /// An income bigger than what is still owed is rejected — the
    /// assign flow never creates prepaid credit.
    @Test func assignRepaymentRejectsOverpayment() throws {
        let context = try makeContext()
        let bank = Account(name: "Ngân hàng", kind: .bank)
        let cash = Account(name: "Tiền mặt", kind: .cash)
        let an = Account(name: "An", kind: .receivable)
        for model in [bank, cash, an] { context.insert(model) }
        context.insert(ReceivableActions.advance(
            receivable: an, from: cash, amount: 900_000,
            date: day(2026, 11, 1), note: ""))
        let income = LedgerTransaction(
            kind: .income, amount: 1_000_000, account: bank)
        context.insert(income)
        try context.save()
        let snapshot = BillSplitOriginal(of: income)

        #expect(throws: BillSplitError.repaymentExceedsOutstanding) {
            try BillSplitService().assignRepayment(
                income, expected: snapshot, to: an, in: context)
        }
        #expect(income.kind == .income)
        #expect(ReceivableSnapshot.make(account: an).outstanding == 900_000)
        #expect(!context.hasChanges)
    }

    /// A zero-amount income is not a repayment — the conversion would
    /// write a meaningless zero movement.
    @Test func assignRepaymentRejectsNonPositiveIncome() throws {
        let context = try makeContext()
        let bank = Account(name: "Ngân hàng", kind: .bank)
        let an = Account(name: "An", kind: .receivable, openingBalance: 100_000)
        context.insert(bank)
        context.insert(an)
        let income = LedgerTransaction(
            kind: .income, amount: 0, account: bank)
        context.insert(income)
        try context.save()
        let snapshot = BillSplitOriginal(of: income)

        #expect(throws: BillSplitError.transactionNotEligible) {
            try BillSplitService().assignRepayment(
                income, expected: snapshot, to: an, in: context)
        }
        #expect(income.kind == .income)
        #expect(!context.hasChanges)
    }

    /// Wrong row kinds, business rows and wrong receivers are rejected;
    /// a business receivable is not a valid target.
    @Test func assignRepaymentRejectsWrongTypeReceiverAndTarget() throws {
        let context = try makeContext()
        let bank = Account(name: "Ngân hàng", kind: .bank)
        let card = Account(name: "Thẻ", kind: .creditCard)
        let an = Account(name: "An", kind: .receivable)
        let business = Business(name: "Chạy ads")
        let businessClient = Account(name: "Khách", kind: .receivable)
        businessClient.business = business
        context.insert(business)
        for model in [bank, card, an, businessClient] { context.insert(model) }
        let service = BillSplitService()

        let expense = LedgerTransaction(
            kind: .expense, amount: 100_000, account: bank)
        let cardIncome = LedgerTransaction(
            kind: .income, amount: 100_000, account: card)
        let businessIncome = LedgerTransaction(
            kind: .income, amount: 100_000, account: bank)
        businessIncome.business = business
        let personalIncome = LedgerTransaction(
            kind: .income, amount: 100_000, account: bank)
        for row in [expense, cardIncome, businessIncome, personalIncome] {
            context.insert(row)
        }
        try context.save()

        for bad in [expense, cardIncome, businessIncome] {
            let snapshot = BillSplitOriginal(of: bad)
            #expect(throws: BillSplitError.transactionNotEligible) {
                try service.assignRepayment(
                    bad, expected: snapshot, to: an, in: context)
            }
        }
        let snapshot = BillSplitOriginal(of: personalIncome)
        #expect(throws: BillSplitError.invalidReceivable) {
            try service.assignRepayment(
                personalIncome, expected: snapshot,
                to: businessClient, in: context)
        }
        #expect(personalIncome.kind == .income)
        #expect(!context.hasChanges)
    }

    /// A second submission of an already-applied assignment fails — the
    /// row is a transfer now and the snapshot no longer matches anyway.
    @Test func assignRepaymentRejectsDoubleApplication() throws {
        let context = try makeContext()
        let bank = Account(name: "Ngân hàng", kind: .bank)
        let cash = Account(name: "Tiền mặt", kind: .cash)
        let an = Account(name: "An", kind: .receivable)
        for model in [bank, cash, an] { context.insert(model) }
        context.insert(ReceivableActions.advance(
            receivable: an, from: cash, amount: 900_000,
            date: day(2026, 11, 1), note: ""))
        let income = LedgerTransaction(
            kind: .income, amount: 500_000, account: bank)
        context.insert(income)
        try context.save()
        let snapshot = BillSplitOriginal(of: income)
        let service = BillSplitService()

        try service.assignRepayment(
            income, expected: snapshot, to: an, in: context)
        #expect(throws: BillSplitError.transactionNotEligible) {
            try service.assignRepayment(
                income, expected: snapshot, to: an, in: context)
        }
        #expect(try fetchAll(LedgerTransaction.self, in: context).count == 2)
        #expect(ReceivableSnapshot.make(account: an).outstanding == 400_000)
    }

    // MARK: - Commit discipline

    /// A failing commit rolls back only the operation's writes — no
    /// half-posted accounts or rows remain.
    @Test func failedCommitRollsBackNewBillWrites() throws {
        let context = try makeContext()
        let cash = Account(name: "Tiền mặt", kind: .cash, openingBalance: 1_000_000)
        context.insert(cash)
        try context.save()
        struct CommitError: Error {}
        let service = BillSplitService(saveAndCheck: { _ in
            throw CommitError()
        })

        #expect(throws: BillSplitError.saveFailed(CommitError())) {
            _ = try service.splitNewBill(
                total: 600_000, payer: cash, date: .now, category: nil,
                note: "", participants: [.newPerson("An")], in: context)
        }
        #expect(try fetchAll(LedgerTransaction.self, in: context).isEmpty)
        #expect(try fetchAll(Account.self, in: context).count == 1)
        #expect(cash.balance == 1_000_000)
        #expect(!context.hasChanges)
    }

    /// The in-place edit is rolled back too — the original amount is
    /// restored and no advance rows survive.
    @Test func failedCommitRollsBackInPlaceSplit() throws {
        let context = try makeContext()
        let cash = Account(name: "Tiền mặt", kind: .cash)
        context.insert(cash)
        let row = LedgerTransaction(
            kind: .expense, amount: 600_000, account: cash,
            needsReview: true)
        context.insert(row)
        try context.save()
        let snapshot = BillSplitOriginal(of: row)
        struct CommitError: Error {}
        let service = BillSplitService(saveAndCheck: { _ in
            throw CommitError()
        })

        #expect(throws: BillSplitError.saveFailed(CommitError())) {
            _ = try service.splitExistingExpense(
                row, expected: snapshot, category: nil,
                participants: [.newPerson("An")], in: context)
        }
        #expect(row.amount == 600_000)
        #expect(row.needsReview)
        #expect(try fetchAll(LedgerTransaction.self, in: context).count == 1)
        #expect(!context.hasChanges)
    }

    /// A context with unrelated pending edits is refused — rolling back
    /// on failure would eat the user's other unsaved changes.
    @Test func dirtyContextIsRefusedAndKeepsPendingEdits() throws {
        let context = try makeContext()
        let cash = Account(name: "Tiền mặt", kind: .cash)
        context.insert(cash)
        try context.save()
        context.insert(LedgerTransaction(
            kind: .expense, amount: 5_000, account: cash))
        #expect(context.hasChanges)

        #expect(throws: BillSplitError.contextHasChanges) {
            _ = try BillSplitService().splitNewBill(
                total: 600_000, payer: cash, date: .now, category: nil,
                note: "", participants: [.newPerson("An")], in: context)
        }
        // The pending row survived — the refusal touched nothing.
        #expect(context.hasChanges)
        #expect(try fetchAll(LedgerTransaction.self, in: context).count == 1)
    }

    /// Every validation error carries a Vietnamese message the UI can
    /// show verbatim.
    @Test func errorsAreLocalizedInVietnamese() {
        let cases: [BillSplitError] = [
            .nonPositiveTotal, .tooFewParticipants, .tooManyParticipants,
            .shareWouldBeZero, .invalidPayer, .emptyParticipantName,
            .duplicateParticipant, .invalidParticipant,
            .participantNameMatchesExisting, .invalidCategory,
            .transactionNotEligible, .staleTransaction, .contextHasChanges,
            .invalidReceivable, .repaymentExceedsOutstanding,
            .saveFailed(URLError(.cannotConnectToHost)),
        ]
        for error in cases {
            #expect(error.errorDescription?.isEmpty == false)
        }
        #expect(BillSplitError.staleTransaction.errorDescription
            == "Giao dịch đã thay đổi — hãy mở lại màn hình xác nhận.")
    }

    // MARK: - UI eligibility mirrors

    /// `canSplitExpense` / `canAssignRepayment` expose the service's
    /// row-level rules to the editor — every ineligible shape is hidden,
    /// every eligible shape passes.
    @Test func uiEligibilityMirrorsServiceGuards() throws {
        let context = try makeContext()
        let cash = Account(name: "Tiền mặt", kind: .cash)
        let card = Account(name: "Thẻ", kind: .creditCard)
        let client = Account(name: "Khách", kind: .receivable)
        let business = Business(name: "Làm web")
        for model in [cash, card, client] { context.insert(model) }
        context.insert(business)
        try context.save()

        let expense = LedgerTransaction(
            kind: .expense, amount: 100_000, account: cash)
        let cardExpense = LedgerTransaction(
            kind: .expense, amount: 100_000, account: card)
        let receivableExpense = LedgerTransaction(
            kind: .expense, amount: 100_000, account: client)
        let businessExpense = LedgerTransaction(
            kind: .expense, amount: 100_000, account: cash)
        businessExpense.business = business
        let income = LedgerTransaction(
            kind: .income, amount: 100_000, account: cash)
        let zeroIncome = LedgerTransaction(
            kind: .income, amount: 0, account: cash)
        let cardIncome = LedgerTransaction(
            kind: .income, amount: 100_000, account: card)
        let transfer = LedgerTransaction(
            kind: .transfer, amount: 100_000,
            account: cash, toAccount: client)

        #expect(BillSplitService.canSplitExpense(expense))
        #expect(BillSplitService.canSplitExpense(cardExpense))
        #expect(!BillSplitService.canSplitExpense(receivableExpense))
        #expect(!BillSplitService.canSplitExpense(businessExpense))
        #expect(!BillSplitService.canSplitExpense(income))
        #expect(!BillSplitService.canSplitExpense(transfer))

        #expect(BillSplitService.canAssignRepayment(income))
        #expect(!BillSplitService.canAssignRepayment(zeroIncome))
        #expect(!BillSplitService.canAssignRepayment(cardIncome))
        #expect(!BillSplitService.canAssignRepayment(expense))
        #expect(!BillSplitService.canAssignRepayment(transfer))
    }
}
