import Testing
import SwiftData
import Foundation
import FinanceCore
@testable import AMFinance

/// Tests for the mixed-batch `AIAgentLedgerTools.apply` — the chat
/// agent's confirmed write layer: `setCategory`, `add`, `edit` and
/// `delete` in one atomic commit, indexed `AIAgentApplyError` failures
/// and the tombstone-aware imported-row rules. Lookup-level behavior
/// stays in `AIAgentTests`; the confirm flow in
/// `AIAgentChatActionTests`.
@MainActor
struct AIAgentActionTests {

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

    /// The working grant for most tests: full access over November 2026
    /// in Vietnam-local days.
    private var window: DateInterval {
        DateInterval(start: day(2026, 11, 1, 0), end: day(2026, 12, 1, 0))
    }

    private func permission(
        _ access: AIAgentAccess = .scopedReadAndProposeCategoryEdits,
        window: DateInterval? = nil
    ) -> AIAgentPermission {
        AIAgentPermission(access: access, window: window ?? self.window)
    }

    private func fetchAll<T: PersistentModel>(
        _ type: T.Type, in context: ModelContext
    ) throws -> [T] {
        try context.fetch(FetchDescriptor<T>())
    }

    /// Seeds a ledger row with the provenance marker a source implies.
    @discardableResult
    private func seed(
        in context: ModelContext,
        kind: TransactionKind = .expense,
        amount: Int64 = 400_000,
        date: Date,
        note: String = "",
        account: Account,
        toAccount: Account? = nil,
        category: LedgerCategory? = nil,
        business: Business? = nil,
        needsReview: Bool = false,
        source: AIAgentSource = .manual
    ) -> LedgerTransaction {
        let row = LedgerTransaction(
            kind: kind, amount: amount, date: date, note: note,
            account: account, toAccount: toAccount, category: category,
            business: business, needsReview: needsReview)
        switch source {
        case .manual:
            break
        case .wallet:
            row.externalSource = WalletSyncEngine.externalSource
            row.externalID = "w-1"
        case .csv:
            row.externalSource = CSVImportDeduper.externalSource
            row.externalID = "c-1"
        case .otherImported:
            row.externalSource = "bank-link"
            row.externalID = "b-1"
        }
        context.insert(row)
        return row
    }

    /// A funded cash + bank pair plus one expense and one income
    /// category, saved and ready.
    @discardableResult
    private func seedBasics(
        in context: ModelContext
    ) throws -> (cash: Account, bank: Account,
                 food: LedgerCategory, salary: LedgerCategory) {
        let cash = Account(name: "Tiền mặt", kind: .cash)
        let bank = Account(name: "VPBank *1234", kind: .bank)
        let food = LedgerCategory(name: "Ăn uống", kind: .expense)
        let salary = LedgerCategory(name: "Lương", kind: .income)
        for model in [cash, bank] { context.insert(model) }
        for model in [food, salary] { context.insert(model) }
        try context.save()
        return (cash, bank, food, salary)
    }

    /// The lookup-issued match for one seeded row.
    private func match(
        _ row: LedgerTransaction,
        in context: ModelContext,
        permission: AIAgentPermission? = nil
    ) throws -> AIAgentLookupMatch {
        let looked = try AIAgentLedgerTools().lookup(
            permission: permission ?? self.permission(), in: context)
        return try #require(looked.matches.first {
            $0.original.id == row.id })
    }

    // MARK: - Happy paths

    /// `add` inserts ordinary manual rows of every kind — no provenance,
    /// no review flag — and the balances move as `LedgerMath` says.
    /// Dated outside the grant on purpose: adds are not window-bound.
    @Test func applyAddsEveryKindAsManualRows() throws {
        let context = try makeContext()
        let (cash, bank, food, salary) = try seedBasics(in: context)
        let tools = AIAgentLedgerTools()

        var expenseDraft = TransactionDraft(kind: .expense, account: cash)
        expenseDraft.amount = 120_000
        expenseDraft.date = day(2025, 3, 10)
        expenseDraft.note = "Bánh mì"
        expenseDraft.category = food

        var incomeDraft = TransactionDraft(kind: .income, account: bank)
        incomeDraft.amount = 5_000_000
        incomeDraft.date = day(2025, 3, 11)
        incomeDraft.note = "Lương"
        incomeDraft.category = salary

        var transferDraft = TransactionDraft(kind: .transfer, account: bank)
        transferDraft.amount = 300_000
        transferDraft.date = day(2025, 3, 12)
        transferDraft.toAccount = cash
        transferDraft.note = "Rút tiền"

        let summary = try tools.apply(
            [.add(draft: expenseDraft), .add(draft: incomeDraft),
             .add(draft: transferDraft)],
            permission: permission(), in: context)
        #expect(summary.added == 3)
        #expect(summary.insertedIDs.count == 3)

        let rows = try fetchAll(LedgerTransaction.self, in: context)
        #expect(rows.count == 3)
        for row in rows {
            #expect(row.externalSource == nil && row.externalID == nil)
            #expect(!row.needsReview)
        }
        #expect(rows.first { $0.kind == .expense }?.category?.id == food.id)
        #expect(rows.first { $0.kind == .income }?.category?.id == salary.id)
        #expect(rows.first { $0.kind == .transfer }?.toAccount?.id == cash.id)
        // cash: -120k expense +300k transfer in = +180k.
        // bank: +5M income -300k transfer out = +4.7M.
        #expect(cash.balance == 180_000)
        #expect(bank.balance == 4_700_000)
        #expect(!context.hasChanges)
    }

    /// An `add` draft failing the editor's own validation — no amount,
    /// no account, a same-account transfer — is refused whole.
    @Test func applyRejectsInvalidAddDrafts() throws {
        let context = try makeContext()
        let (cash, bank, food, _) = try seedBasics(in: context)
        let tools = AIAgentLedgerTools()

        var noAmount = TransactionDraft(kind: .expense, account: cash)
        noAmount.category = food
        #expect(throws: AIAgentApplyError.action(0, .invalidDraft)) {
            _ = try tools.apply(
                [.add(draft: noAmount)],
                permission: permission(), in: context)
        }

        var noAccount = TransactionDraft(kind: .expense)
        noAccount.amount = 10_000
        noAccount.category = food
        #expect(throws: AIAgentApplyError.action(0, .invalidDraft)) {
            _ = try tools.apply(
                [.add(draft: noAccount)],
                permission: permission(), in: context)
        }

        var sameLegs = TransactionDraft(kind: .transfer, account: cash)
        sameLegs.amount = 10_000
        sameLegs.toAccount = cash
        #expect(throws: AIAgentApplyError.action(0, .invalidDraft)) {
            _ = try tools.apply(
                [.add(draft: sameLegs)],
                permission: permission(), in: context)
        }

        // An archived or foreign category / account is refused too.
        let archived = LedgerCategory(
            name: "Cũ", kind: .expense, isArchived: true)
        context.insert(archived)
        try context.save()
        var archivedCategory = TransactionDraft(kind: .expense, account: cash)
        archivedCategory.amount = 10_000
        archivedCategory.category = archived
        #expect(throws: AIAgentApplyError.action(0, .invalidCategory)) {
            _ = try tools.apply(
                [.add(draft: archivedCategory)],
                permission: permission(), in: context)
        }
        var archivedAccount = TransactionDraft(
            kind: .expense, account: bank)
        archivedAccount.amount = 10_000
        archivedAccount.account = Account(
            name: "Đã ẩn", kind: .cash, isArchived: true)
        #expect(throws: AIAgentApplyError.action(0, .invalidDraft)) {
            _ = try tools.apply(
                [.add(draft: archivedAccount)],
                permission: permission(), in: context)
        }
        #expect(try fetchAll(LedgerTransaction.self, in: context).isEmpty)
        #expect(!context.hasChanges)
    }

    /// `edit` rewrites an expense's allowed fields in place — amount,
    /// date, note, source account, category — while kind, business,
    /// provenance and id survive, and the balance follows the move.
    @Test func applyEditsIncomeExpenseRows() throws {
        let context = try makeContext()
        let (cash, bank, food, salary) = try seedBasics(in: context)
        let business = Business(name: "Chạy ads")
        context.insert(business)
        let row = seed(in: context, amount: 125_000,
                       date: day(2026, 11, 10), note: "GRAB",
                       account: cash, business: business,
                       source: .wallet)
        try context.save()
        let stamp = row.updatedAt
        let tools = AIAgentLedgerTools()
        let m = try match(row, in: context)

        var draft = TransactionDraft(transaction: row)
        draft.amount = 95_000
        draft.date = day(2026, 11, 12)
        draft.note = "GRAB đã sửa"
        draft.account = bank
        draft.category = food

        let summary = try tools.apply(
            [.edit(match: m, draft: draft)],
            permission: permission(), in: context)
        #expect(summary.edited == 1)
        #expect(row.amount == 95_000)
        #expect(row.date == day(2026, 11, 12))
        #expect(row.note == "GRAB đã sửa")
        #expect(row.account?.id == bank.id)
        #expect(row.category?.id == food.id)
        #expect(row.business?.id == business.id)
        #expect(row.kind == .expense)
        #expect(row.externalSource == WalletSyncEngine.externalSource)
        #expect(row.externalID == "w-1")
        #expect(row.updatedAt > stamp)
        #expect(cash.balance == 0 && bank.balance == -95_000)
        #expect(!context.hasChanges)
    }

    /// A transfer edit may move amount, date and note only — the legs
    /// stay put and both balances follow.
    @Test func applyEditsTransferAmountDateAndNoteOnly() throws {
        let context = try makeContext()
        let (cash, bank, _, _) = try seedBasics(in: context)
        let row = seed(in: context, kind: .transfer, amount: 500_000,
                       date: day(2026, 11, 10), note: "Chuyển",
                       account: cash, toAccount: bank)
        try context.save()
        let tools = AIAgentLedgerTools()
        let m = try match(row, in: context)

        var draft = TransactionDraft(transaction: row)
        draft.amount = 250_000
        draft.date = day(2026, 11, 11)
        draft.note = "Chuyển ít hơn"

        let summary = try tools.apply(
            [.edit(match: m, draft: draft)],
            permission: permission(), in: context)
        #expect(summary.edited == 1)
        #expect(row.kind == .transfer)
        #expect(row.amount == 250_000 && row.date == day(2026, 11, 11))
        #expect(row.note == "Chuyển ít hơn")
        #expect(row.account?.id == cash.id && row.toAccount?.id == bank.id)
        #expect(row.category == nil)
        #expect(cash.balance == -250_000 && bank.balance == 250_000)
    }

    /// Every transfer-leg or kind change is refused — the row is
    /// editable only within its narrow surface.
    @Test func applyRefusesTransferAccountCategoryAndKindEdits() throws {
        let context = try makeContext()
        let (cash, bank, food, _) = try seedBasics(in: context)
        let row = seed(in: context, kind: .transfer, amount: 500_000,
                       date: day(2026, 11, 10), account: cash,
                       toAccount: bank)
        try context.save()
        let tools = AIAgentLedgerTools()
        let m = try match(row, in: context)

        func draftWith(
            _ mutate: (inout TransactionDraft) -> Void
        ) -> TransactionDraft {
            var draft = TransactionDraft(transaction: row)
            mutate(&draft)
            return draft
        }
        let third = Account(name: "Ví MoMo", kind: .eWallet)
        context.insert(third)
        try context.save()

        for draft in [
            draftWith { $0.account = third },
            draftWith { $0.toAccount = third },
            draftWith { $0.category = food },
            draftWith { $0.business = Business(name: "Shop") },
            draftWith { $0.kind = .expense },
        ] {
            #expect(throws: AIAgentApplyError.action(0, .invalidEdit)) {
                _ = try tools.apply(
                    [.edit(match: m, draft: draft)],
                    permission: permission(), in: context)
            }
        }
        #expect(row.amount == 500_000 && row.kind == .transfer)
        #expect(row.account?.id == cash.id && row.toAccount?.id == bank.id)
        #expect(!context.hasChanges)
    }

    /// Income/expense edits may not touch business or a destination —
    /// those are outside the confirmed surface.
    @Test func applyRefusesIncomeExpenseFieldEscapes() throws {
        let context = try makeContext()
        let (cash, bank, _, _) = try seedBasics(in: context)
        let row = seed(in: context, date: day(2026, 11, 10), account: cash)
        try context.save()
        let tools = AIAgentLedgerTools()
        let m = try match(row, in: context)

        var kindChange = TransactionDraft(transaction: row)
        kindChange.kind = .income
        #expect(throws: AIAgentApplyError.action(0, .invalidEdit)) {
            _ = try tools.apply(
                [.edit(match: m, draft: kindChange)],
                permission: permission(), in: context)
        }

        var business = TransactionDraft(transaction: row)
        business.business = Business(name: "Tiệm")
        #expect(throws: AIAgentApplyError.action(0, .invalidEdit)) {
            _ = try tools.apply(
                [.edit(match: m, draft: business)],
                permission: permission(), in: context)
        }

        var toAccount = TransactionDraft(transaction: row)
        toAccount.toAccount = bank
        #expect(throws: AIAgentApplyError.action(0, .invalidEdit)) {
            _ = try tools.apply(
                [.edit(match: m, draft: toAccount)],
                permission: permission(), in: context)
        }
        #expect(row.business == nil && row.toAccount == nil)
        #expect(!context.hasChanges)
    }

    /// `delete` removes rows through the tombstone-aware helper — a
    /// manual row just disappears and the balance reverts.
    @Test func applyDeletesRows() throws {
        let context = try makeContext()
        let (cash, bank, _, _) = try seedBasics(in: context)
        let expense = seed(in: context, amount: 100_000,
                           date: day(2026, 11, 10), account: cash)
        let transfer = seed(in: context, kind: .transfer, amount: 50_000,
                            date: day(2026, 11, 11), account: cash,
                            toAccount: bank)
        try context.save()
        let tools = AIAgentLedgerTools()
        let looked = try tools.lookup(permission: permission(), in: context)
        let matches = looked.matches.filter {
            $0.original.id == expense.id || $0.original.id == transfer.id
        }
        #expect(matches.count == 2)

        let summary = try tools.apply(
            matches.map { .delete(match: $0) },
            permission: permission(), in: context)
        #expect(summary.deleted == 2)
        #expect(try fetchAll(LedgerTransaction.self, in: context).isEmpty)
        #expect(cash.balance == 0 && bank.balance == 0)
        #expect(!context.hasChanges)
    }

    /// `setCategory` through the new entry point behaves exactly like
    /// the legacy apply — provenance and identity preserved.
    @Test func applySetCategoryMatchesLegacyBehaviour() throws {
        let context = try makeContext()
        let (cash, _, food, _) = try seedBasics(in: context)
        let row = seed(in: context, date: day(2026, 11, 10),
                       account: cash, needsReview: true, source: .wallet)
        try context.save()
        let tools = AIAgentLedgerTools()
        let m = try match(row, in: context)

        let summary = try tools.apply(
            [.setCategory(match: m, category: food)],
            permission: permission(), in: context)
        #expect(summary.categorized == 1)
        #expect(row.category?.id == food.id && !row.needsReview)
        #expect(row.externalID == "w-1")
    }

    /// One confirmed batch may mix every action kind — all four land in
    /// a single commit and the summary counts each kind.
    @Test func applyLandsMixedBatchAtomically() throws {
        let context = try makeContext()
        let (cash, bank, food, _) = try seedBasics(in: context)
        let categorize = seed(in: context, amount: 40_000,
                              date: day(2026, 11, 10), account: cash)
        let edit = seed(in: context, amount: 60_000,
                        date: day(2026, 11, 11), account: cash)
        let delete = seed(in: context, amount: 10_000,
                          date: day(2026, 11, 12), account: cash)
        try context.save()
        let tools = AIAgentLedgerTools()
        let looked = try tools.lookup(permission: permission(), in: context)
        func match(_ row: LedgerTransaction) throws -> AIAgentLookupMatch {
            try #require(looked.matches.first { $0.original.id == row.id })
        }

        var addDraft = TransactionDraft(kind: .expense, account: bank)
        addDraft.amount = 20_000
        addDraft.date = day(2026, 11, 13)
        var editDraft = TransactionDraft(transaction: edit)
        editDraft.amount = 75_000

        let summary = try tools.apply(
            [.setCategory(match: try match(categorize), category: food),
             .add(draft: addDraft),
             .edit(match: try match(edit), draft: editDraft),
             .delete(match: try match(delete))],
            permission: permission(), in: context)
        #expect(summary.categorized == 1 && summary.added == 1)
        #expect(summary.edited == 1 && summary.deleted == 1)
        #expect(summary.insertedIDs.count == 1)
        #expect(categorize.category?.id == food.id)
        #expect(edit.amount == 75_000)
        let rows = try fetchAll(LedgerTransaction.self, in: context)
        #expect(rows.count == 3)
        #expect(rows.contains { $0.id == summary.insertedIDs[0] })
        #expect(!rows.contains { $0.id == delete.id })
        #expect(!context.hasChanges)
    }

    // MARK: - Refusals

    /// One stale target poisons the whole batch — the valid categorize,
    /// the add and the delete all stay unwritten.
    @Test func applyIsAtomicWhenAnyActionIsStale() throws {
        let context = try makeContext()
        let (cash, bank, food, _) = try seedBasics(in: context)
        let stale = seed(in: context, date: day(2026, 11, 10),
                         account: cash)
        let clean = seed(in: context, date: day(2026, 11, 11),
                         account: bank)
        try context.save()
        let tools = AIAgentLedgerTools()
        let looked = try tools.lookup(permission: permission(), in: context)
        func match(_ row: LedgerTransaction) throws -> AIAgentLookupMatch {
            try #require(looked.matches.first { $0.original.id == row.id })
        }
        var addDraft = TransactionDraft(kind: .expense, account: cash)
        addDraft.amount = 30_000
        addDraft.date = day(2026, 11, 12)

        // Confirmed, then someone edited the first row.
        stale.note = "Đã sửa"
        stale.updatedAt = .now
        try context.save()

        #expect(throws: AIAgentApplyError.action(1, .staleTransaction)) {
            _ = try tools.apply(
                [.setCategory(match: try match(clean), category: food),
                 .delete(match: try match(stale)),
                 .add(draft: addDraft)],
                permission: permission(), in: context)
        }
        #expect(clean.category == nil && stale.category == nil)
        // Nothing landed — the add never persisted either.
        #expect(try fetchAll(LedgerTransaction.self, in: context).count == 2)
        #expect(!context.hasChanges)
    }

    /// A deleted target fails the batch the same way a changed one does.
    @Test func applyRejectsDeletedRows() throws {
        let context = try makeContext()
        let (cash, _, food, _) = try seedBasics(in: context)
        let row = seed(in: context, date: day(2026, 11, 10), account: cash)
        try context.save()
        let tools = AIAgentLedgerTools()
        let m = try match(row, in: context)

        context.delete(row)
        try context.save()

        #expect(throws: AIAgentApplyError.action(0, .staleTransaction)) {
            _ = try tools.apply(
                [.setCategory(match: m, category: food)],
                permission: permission(), in: context)
        }
        #expect(try fetchAll(LedgerTransaction.self, in: context).isEmpty)
    }

    /// Rental-linked rows are refused for edit AND delete — a lease's
    /// rent month cannot silently change or disappear.
    @Test func applyRefusesRentalLinkedRows() throws {
        let context = try makeContext()
        let (cash, bank, _, _) = try seedBasics(in: context)
        let rent = seed(in: context, kind: .income, amount: 4_000_000,
                        date: day(2026, 11, 10), account: bank)
        rent.rentalPeriod = day(2026, 11, 1)
        let plain = seed(in: context, date: day(2026, 11, 11),
                         account: cash)
        try context.save()
        let tools = AIAgentLedgerTools()
        let looked = try tools.lookup(permission: permission(), in: context)
        func match(_ row: LedgerTransaction) throws -> AIAgentLookupMatch {
            try #require(looked.matches.first { $0.original.id == row.id })
        }
        let rentMatch = try match(rent)

        var draft = TransactionDraft(transaction: rent)
        draft.amount = 5_000_000
        #expect(throws: AIAgentApplyError.action(0, .transactionNotEligible)) {
            _ = try tools.apply(
                [.edit(match: rentMatch, draft: draft)],
                permission: permission(), in: context)
        }
        #expect(throws: AIAgentApplyError.action(0, .transactionNotEligible)) {
            _ = try tools.apply(
                [.delete(match: rentMatch)],
                permission: permission(), in: context)
        }
        // A mixed batch dies whole — the plain row is not deleted either.
        #expect(throws: AIAgentApplyError.action(1, .transactionNotEligible)) {
            _ = try tools.apply(
                [.delete(match: try match(plain)),
                 .delete(match: rentMatch)],
                permission: permission(), in: context)
        }
        #expect(try fetchAll(LedgerTransaction.self, in: context).count == 2)
        #expect(!context.hasChanges)
    }

    /// Editing an imported row keeps its external provenance and stamps
    /// `updatedAt` — exactly like the manual editor.
    @Test func applyEditKeepsProvenanceAndStampsUpdatedAt() throws {
        let context = try makeContext()
        let (cash, _, _, _) = try seedBasics(in: context)
        let row = seed(in: context, amount: 200_000,
                       date: day(2026, 11, 10), note: "Bank row",
                       account: cash, source: .wallet)
        try context.save()
        let stamp = row.updatedAt
        let tools = AIAgentLedgerTools()
        let m = try match(row, in: context)

        var draft = TransactionDraft(transaction: row)
        draft.amount = 180_000
        _ = try tools.apply(
            [.edit(match: m, draft: draft)],
            permission: permission(), in: context)
        #expect(row.externalSource == WalletSyncEngine.externalSource)
        #expect(row.externalID == "w-1")
        #expect(row.updatedAt > stamp)
        #expect(cash.balance == -180_000)
    }

    /// Deleting an imported row tombstones its external id in the sync
    /// state store — the next rescan never resurrects it.
    @Test func applyDeleteTombstonesImportedRows() throws {
        let context = try makeContext()
        let (cash, _, _, _) = try seedBasics(in: context)
        let synced = seed(in: context, date: day(2026, 11, 10),
                          account: cash, source: .wallet)
        let manual = seed(in: context, date: day(2026, 11, 11),
                          account: cash)
        try context.save()
        let states = WalletSyncInMemoryStateStore()
        let tools = AIAgentLedgerTools(tombstones: states)
        let looked = try tools.lookup(permission: permission(), in: context)
        func match(_ row: LedgerTransaction) throws -> AIAgentLookupMatch {
            try #require(looked.matches.first { $0.original.id == row.id })
        }

        let summary = try tools.apply(
            [.delete(match: try match(synced)),
             .delete(match: try match(manual))],
            permission: permission(), in: context)
        #expect(summary.deleted == 2)
        #expect(states.tombstonedIDs(
            source: WalletSyncEngine.externalSource) == ["w-1"])
        #expect(try fetchAll(LedgerTransaction.self, in: context).isEmpty)
    }

    /// One invalid action in a mixed batch — here a wrong-kind category
    /// on the third action — leaves every earlier action unwritten.
    @Test func applyIsAtomicWhenAnActionIsInvalid() throws {
        let context = try makeContext()
        let (cash, _, food, salary) = try seedBasics(in: context)
        let categorize = seed(in: context, date: day(2026, 11, 10),
                              account: cash)
        let other = seed(in: context, date: day(2026, 11, 11),
                         account: cash)
        try context.save()
        let tools = AIAgentLedgerTools()
        let looked = try tools.lookup(permission: permission(), in: context)
        func match(_ row: LedgerTransaction) throws -> AIAgentLookupMatch {
            try #require(looked.matches.first { $0.original.id == row.id })
        }
        var addDraft = TransactionDraft(kind: .expense, account: cash)
        addDraft.amount = 30_000
        addDraft.date = day(2026, 11, 12)

        // salary is an income category — wrong kind for an expense row.
        #expect(throws: AIAgentApplyError.action(2, .invalidCategory)) {
            _ = try tools.apply(
                [.add(draft: addDraft),
                 .setCategory(match: try match(categorize), category: food),
                 .setCategory(match: try match(other), category: salary)],
                permission: permission(), in: context)
        }
        #expect(categorize.category == nil && other.category == nil)
        // Nothing landed — the add never persisted either.
        #expect(try fetchAll(LedgerTransaction.self, in: context).count == 2)
        #expect(!context.hasChanges)
    }

    /// A failed commit rolls back the batch's writes — no
    /// half-categorized rows, no inserted adds.
    @Test func failedSaveRollsBackTheWholeBatch() throws {
        let context = try makeContext()
        let (cash, _, food, _) = try seedBasics(in: context)
        let row = seed(in: context, date: day(2026, 11, 10), account: cash)
        try context.save()
        let m = try match(row, in: context)
        var addDraft = TransactionDraft(kind: .expense, account: cash)
        addDraft.amount = 30_000

        struct CommitError: Error {}
        let failing = AIAgentLedgerTools(saveAndCheck: { _ in
            throw CommitError()
        })
        #expect(throws: AIAgentApplyError.batch(.saveFailed(CommitError()))) {
            _ = try failing.apply(
                [.setCategory(match: m, category: food),
                 .add(draft: addDraft)],
                permission: permission(), in: context)
        }
        #expect(row.category == nil)
        #expect(try fetchAll(LedgerTransaction.self, in: context).count == 1)
        #expect(!context.hasChanges)
    }

    /// A context holding unrelated pending edits is refused — a
    /// rollback on failure would eat them.
    @Test func applyRefusesDirtyContext() throws {
        let context = try makeContext()
        let (cash, _, _, _) = try seedBasics(in: context)
        _ = seed(in: context, date: day(2026, 11, 10), account: cash)
        try context.save()
        var addDraft = TransactionDraft(kind: .expense, account: cash)
        addDraft.amount = 30_000

        context.insert(LedgerTransaction(
            kind: .expense, amount: 5_000, account: cash))
        #expect(context.hasChanges)

        #expect(throws: AIAgentApplyError.batch(.contextHasChanges)) {
            _ = try AIAgentLedgerTools().apply(
                [.add(draft: addDraft)],
                permission: permission(), in: context)
        }
        #expect(context.hasChanges)
    }

    /// Read-only and off grants can look but never write — the apply
    /// re-checks the level itself.
    @Test func applyRefusesReadOnlyAndOffGrants() throws {
        let context = try makeContext()
        let (cash, _, _, _) = try seedBasics(in: context)
        _ = seed(in: context, date: day(2026, 11, 10), account: cash)
        try context.save()
        var addDraft = TransactionDraft(kind: .expense, account: cash)
        addDraft.amount = 30_000
        let tools = AIAgentLedgerTools()

        #expect(!AIAgentAccess.scopedRead.canProposeActions)
        #expect(AIAgentAccess.scopedReadAndProposeCategoryEdits
            .canProposeActions)
        #expect(!AIAgentAccess.off.canProposeActions)

        #expect(throws: AIAgentApplyError.batch(.permissionDenied)) {
            _ = try tools.apply(
                [.add(draft: addDraft)],
                permission: permission(.scopedRead), in: context)
        }
        #expect(throws: AIAgentApplyError.batch(.permissionDenied)) {
            _ = try tools.apply(
                [.add(draft: addDraft)],
                permission: .off, in: context)
        }
        #expect(try fetchAll(LedgerTransaction.self, in: context).count == 1)
    }

    /// The same row targeted twice — across different action kinds —
    /// is refused before any write.
    @Test func applyRejectsDuplicateTargetsAcrossKinds() throws {
        let context = try makeContext()
        let (cash, _, food, _) = try seedBasics(in: context)
        let row = seed(in: context, date: day(2026, 11, 10), account: cash)
        try context.save()
        let tools = AIAgentLedgerTools()
        let m = try match(row, in: context)
        var draft = TransactionDraft(transaction: row)
        draft.amount = 99_000

        for actions in [
            [AIAgentLedgerAction.setCategory(match: m, category: food),
             .delete(match: m)],
            [.delete(match: m), .edit(match: m, draft: draft)],
        ] {
            #expect(throws: AIAgentApplyError
                .action(1, .duplicateTransaction)) {
                _ = try tools.apply(
                    actions, permission: permission(), in: context)
            }
        }
        #expect(row.category == nil)
        #expect(!context.hasChanges)
    }

    /// Edits and categorizes that would change nothing are refused.
    @Test func applyRejectsNoOpEdits() throws {
        let context = try makeContext()
        let (cash, _, food, _) = try seedBasics(in: context)
        let categorized = seed(in: context, date: day(2026, 11, 10),
                               account: cash, category: food)
        let plain = seed(in: context, date: day(2026, 11, 11),
                         account: cash)
        try context.save()
        let tools = AIAgentLedgerTools()
        let looked = try tools.lookup(permission: permission(), in: context)
        func match(_ row: LedgerTransaction) throws -> AIAgentLookupMatch {
            try #require(looked.matches.first { $0.original.id == row.id })
        }

        #expect(throws: AIAgentApplyError.action(0, .noOpEdit)) {
            _ = try tools.apply(
                [.setCategory(match: try match(categorized),
                              category: food)],
                permission: permission(), in: context)
        }
        // Identical editable fields — no-op too.
        let identical = TransactionDraft(transaction: plain)
        #expect(throws: AIAgentApplyError.action(0, .noOpEdit)) {
            _ = try tools.apply(
                [.edit(match: try match(plain), draft: identical)],
                permission: permission(), in: context)
        }
        // …but a pending-review row re-confirmed is a real edit.
        plain.needsReview = true
        plain.updatedAt = .now
        try context.save()
        let fresh = try self.match(plain, in: context)
        let summary = try tools.apply(
            [.edit(match: fresh, draft: identical)],
            permission: permission(), in: context)
        #expect(summary.edited == 1)
        #expect(!plain.needsReview)
        #expect(!context.hasChanges)
    }

    /// Empty and oversized batches are refused before any work.
    @Test func applyRejectsEmptyAndOversizedBatches() throws {
        let context = try makeContext()
        let (cash, _, _, _) = try seedBasics(in: context)
        let tools = AIAgentLedgerTools()
        var addDraft = TransactionDraft(kind: .expense, account: cash)
        addDraft.amount = 10_000

        #expect(throws: AIAgentApplyError.batch(.emptyBatch)) {
            _ = try tools.apply(
                [], permission: permission(), in: context)
        }
        let oversized = (0...AIAgentLedgerTools.actionLimit).map { _ in
            AIAgentLedgerAction.add(draft: addDraft)
        }
        #expect(oversized.count == AIAgentLedgerTools.actionLimit + 1)
        #expect(throws: AIAgentApplyError.batch(.tooManyActions)) {
            _ = try tools.apply(
                oversized, permission: permission(), in: context)
        }
        #expect(try fetchAll(LedgerTransaction.self, in: context).isEmpty)
    }

    /// A match surfaced by a lookup is the only way to address a row —
    /// a snapshot date outside the granted window is refused.
    @Test func applyRejectsRowsOutsideTheWindow() throws {
        let context = try makeContext()
        let (cash, _, _, _) = try seedBasics(in: context)
        let row = seed(in: context, date: day(2026, 11, 28), account: cash)
        try context.save()
        let tools = AIAgentLedgerTools()
        let m = try match(row, in: context)

        let narrower = permission(
            window: DateInterval(
                start: day(2026, 11, 1, 0), end: day(2026, 11, 20, 0)))
        #expect(throws: AIAgentApplyError.action(0, .rowOutsideWindow)) {
            _ = try tools.apply(
                [.delete(match: m)],
                permission: narrower, in: context)
        }
        #expect(try fetchAll(LedgerTransaction.self, in: context).count == 1)
    }

    /// Every apply failure carries a Vietnamese message through
    /// `reason`, whatever shape it arrived in.
    @Test func applyErrorsAreLocalizedAndIndexed() throws {
        let cases: [AIAgentApplyError] = [
            .batch(.permissionDenied), .batch(.tooManyActions),
            .batch(.contextHasChanges), .action(0, .invalidDraft),
            .action(3, .invalidEdit), .action(7, .staleTransaction),
        ]
        for error in cases {
            #expect(error.errorDescription?.isEmpty == false)
        }
        #expect(AIAgentApplyError.action(4, .noOpEdit).actionIndex == 4)
        #expect(AIAgentApplyError.action(4, .noOpEdit).reason == .noOpEdit)
        #expect(AIAgentApplyError.batch(.emptyBatch).actionIndex == nil)
        #expect(AIAgentApplyError.batch(.emptyBatch).reason == .emptyBatch)
    }

    // MARK: - validate (the dry run)

    /// `validate` runs the same checks as `apply` — permission, batch
    /// shape, snapshot freshness, eligibility, drafts — but mutates
    /// nothing, never calls the commit seam and leaves no pending
    /// changes. The chat session dry-runs proposals through it.
    @Test func validateChecksWithoutWritingOrSaving() throws {
        let context = try makeContext()
        let (cash, _, food, _) = try seedBasics(in: context)
        let categorize = seed(in: context, date: day(2026, 11, 9),
                              account: cash)
        let row = seed(in: context, date: day(2026, 11, 10),
                       account: cash)
        let doomed = seed(in: context, amount: 10_000,
                          date: day(2026, 11, 11), account: cash)
        try context.save()
        let stamp = row.updatedAt
        let looked = try AIAgentLedgerTools().lookup(
            permission: permission(), in: context)
        func match(_ row: LedgerTransaction) throws -> AIAgentLookupMatch {
            try #require(looked.matches.first { $0.original.id == row.id })
        }
        var addDraft = TransactionDraft(kind: .expense, account: cash)
        addDraft.amount = 30_000
        addDraft.date = day(2026, 11, 12)
        var editDraft = TransactionDraft(transaction: row)
        editDraft.amount = 99_000

        var saved = false
        let probing = AIAgentLedgerTools(saveAndCheck: { _ in
            saved = true
        })
        try probing.validate(
            [.setCategory(match: try match(categorize), category: food),
             .add(draft: addDraft),
             .edit(match: try match(row), draft: editDraft),
             .delete(match: try match(doomed))],
            permission: permission(), in: context)
        #expect(!saved)
        #expect(categorize.category == nil)
        #expect(row.category == nil && row.amount == 400_000)
        #expect(row.updatedAt == stamp)
        #expect(try fetchAll(LedgerTransaction.self, in: context).count == 3)
        #expect(!context.hasChanges)
    }

    /// `validate` throws the same indexed `.action`/`.batch` shapes
    /// `apply` throws — a dry-run refusal reads identically.
    @Test func validateThrowsTheSameErrorShapes() throws {
        let context = try makeContext()
        let (cash, _, food, _) = try seedBasics(in: context)
        let row = seed(in: context, date: day(2026, 11, 10),
                       account: cash)
        try context.save()
        let tools = AIAgentLedgerTools()
        let m = try match(row, in: context)

        // Batch-level: permission and empty batch.
        #expect(throws: AIAgentApplyError.batch(.permissionDenied)) {
            try tools.validate(
                [.setCategory(match: m, category: food)],
                permission: permission(.scopedRead), in: context)
        }
        #expect(throws: AIAgentApplyError.batch(.emptyBatch)) {
            try tools.validate([], permission: permission(), in: context)
        }
        // Indexed: a stale target fails at its index.
        row.note = "đổi"
        row.updatedAt = .now
        try context.save()
        #expect(throws: AIAgentApplyError.action(0, .staleTransaction)) {
            try tools.validate(
                [.delete(match: m)],
                permission: permission(), in: context)
        }
        // A dirty context is refused before looking at actions.
        context.insert(LedgerTransaction(
            kind: .expense, amount: 1_000, account: cash))
        #expect(throws: AIAgentApplyError.batch(.contextHasChanges)) {
            try tools.validate(
                [.delete(match: m)],
                permission: permission(), in: context)
        }
        context.rollback()
        #expect(!context.hasChanges)
    }

    /// A batch that validates applies identically afterwards — the
    /// dry-run consumes nothing: no handle state, no staleness.
    @Test func validateThenApplyLandsTheBatch() throws {
        let context = try makeContext()
        let (cash, _, food, _) = try seedBasics(in: context)
        let row = seed(in: context, date: day(2026, 11, 10),
                       account: cash, needsReview: true)
        try context.save()
        let tools = AIAgentLedgerTools()
        let m = try match(row, in: context)
        let actions: [AIAgentLedgerAction] = [
            .setCategory(match: m, category: food)]

        try tools.validate(
            actions, permission: permission(), in: context)
        let summary = try tools.apply(
            actions, permission: permission(), in: context)
        #expect(summary.categorized == 1)
        #expect(row.category?.id == food.id)
        #expect(!row.needsReview)
    }

    /// `lookupWindow` re-resolves inside the narrowed slice the lookup
    /// actually scanned — a row older than the grant's first
    /// `scanLimit` entries still applies when its window is passed
    /// back, exactly like the chat confirm path does.
    @Test func applyReResolvesInsideNarrowedLookupWindow() throws {
        let context = try makeContext()
        let (cash, _, food, _) = try seedBasics(in: context)
        // Five newest-first rows, the oldest two inside the narrow
        // window — a scanLimit of three cannot see them on its own.
        var older: [LedgerTransaction] = []
        for dayOfMonth in [26, 25, 20, 11, 10] {
            let row = seed(in: context, amount: 10_000,
                           date: day(2026, 11, dayOfMonth), account: cash)
            if dayOfMonth <= 11 { older.append(row) }
        }
        try context.save()
        let tools = AIAgentLedgerTools(scanLimit: 3)

        let narrow = DateInterval(
            start: day(2026, 11, 1, 0), end: day(2026, 11, 15, 0))
        let looked = try tools.lookup(
            AIAgentLookupQuery(interval: narrow),
            permission: permission(), in: context)
        #expect(looked.matches.count == 2)
        #expect(looked.window == narrow)
        let match = try #require(looked.matches.first {
            $0.original.id == older[1].id })

        // Without the narrowed window the apply cannot even see the row.
        #expect(throws: AIAgentApplyError.action(0, .staleTransaction)) {
            _ = try tools.apply(
                [.setCategory(match: match, category: food)],
                permission: permission(), in: context)
        }
        // With it, the row re-resolves and the edit lands.
        let summary = try tools.apply(
            [.setCategory(match: match, category: food)],
            permission: permission(), in: context,
            lookupWindow: narrow)
        #expect(summary.categorized == 1)
        #expect(older[1].category?.id == food.id)

        // A window escaping the grant is still refused, not clipped.
        #expect(throws: AIAgentApplyError.batch(.queryOutsideWindow)) {
            _ = try tools.apply(
                [.setCategory(match: match, category: food)],
                permission: permission(), in: context,
                lookupWindow: DateInterval(
                    start: day(2026, 10, 1, 0), end: day(2026, 12, 1, 0)))
        }
    }
}
