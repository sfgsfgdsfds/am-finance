import Testing
import SwiftData
import Foundation
import FinanceCore
@testable import AMFinance

@MainActor
struct AIAgentTests {

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
    /// in Vietnam-local days ([Nov 1 00:00, Dec 1 00:00) — 30 days, well
    /// inside the ~3-month cap).
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

    // MARK: - Permission gate

    /// The default grant is off — both tools refuse before touching data.
    @Test func offPermissionDeniesLookupAndApply() throws {
        let context = try makeContext()
        let (_, _, food, _) = try seedBasics(in: context)
        let tools = AIAgentLedgerTools()

        #expect(AIAgentPermission.off.access == .off)
        #expect(!AIAgentAccess.off.canLookup)
        #expect(!AIAgentAccess.off.canProposeActions)
        #expect(throws: AIAgentError.permissionDenied) {
            _ = try tools.lookup(permission: .off, in: context)
        }
        #expect(throws: AIAgentApplyError.batch(.permissionDenied)) {
            _ = try tools.apply(
                [], permission: .off, in: context)
        }
    }

    /// A read-only grant can look but never write — the apply re-checks.
    @Test func readOnlyGrantCannotApply() throws {
        let context = try makeContext()
        let (cash, _, food, _) = try seedBasics(in: context)
        let row = seed(in: context, date: day(2026, 11, 10), account: cash)
        try context.save()
        let tools = AIAgentLedgerTools()
        let read = permission(.scopedRead)

        let result = try tools.lookup(permission: read, in: context)
        #expect(result.matches.count == 1)

        #expect(throws: AIAgentApplyError.batch(.permissionDenied)) {
            _ = try tools.apply(
                [.setCategory(match: result.matches[0], category: food)],
                permission: read, in: context)
        }
        #expect(row.category == nil)
        #expect(row.needsReview == false)
    }

    /// A grant wider than 366 days is refused, not clipped — on both
    /// tools. A full-year grant still passes.
    @Test func windowTooWideIsRejected() throws {
        let context = try makeContext()
        let (cash, _, _, _) = try seedBasics(in: context)
        seed(in: context, date: day(2026, 11, 10), account: cash)
        try context.save()
        let tools = AIAgentLedgerTools()
        let wide = permission(
            window: DateInterval(
                start: day(2026, 1, 1, 0), end: day(2027, 2, 1, 0)))

        #expect(throws: AIAgentError.windowTooWide) {
            _ = try tools.lookup(permission: wide, in: context)
        }
        #expect(throws: AIAgentApplyError.batch(.windowTooWide)) {
            _ = try tools.apply(
                [], permission: wide, in: context)
        }

        // Dec 1 2025 → Dec 1 2026 is 365 days — a full-year grant works.
        let fullYear = permission(
            window: DateInterval(
                start: day(2025, 12, 1, 0), end: day(2026, 12, 1, 0)))
        _ = try tools.lookup(permission: fullYear, in: context)
    }

    /// The query interval may narrow the grant, never escape it.
    @Test func queryMayNarrowButNeverEscapeTheWindow() throws {
        let context = try makeContext()
        let (cash, _, _, _) = try seedBasics(in: context)
        seed(in: context, date: day(2026, 11, 10), account: cash)
        try context.save()
        let tools = AIAgentLedgerTools()

        let narrowed = try tools.lookup(
            AIAgentLookupQuery(interval: DateInterval(
                start: day(2026, 11, 5, 0), end: day(2026, 11, 20, 0))),
            permission: permission(), in: context)
        #expect(narrowed.matches.count == 1)
        #expect(narrowed.window.start == day(2026, 11, 5, 0))

        for bad in [
            // Starts before the grant.
            DateInterval(start: day(2026, 10, 1, 0), end: day(2026, 11, 20, 0)),
            // Ends after the grant.
            DateInterval(start: day(2026, 11, 5, 0), end: day(2026, 12, 2, 0)),
            // Fully outside.
            DateInterval(start: day(2027, 1, 1, 0), end: day(2027, 1, 10, 0)),
        ] {
            #expect(throws: AIAgentError.queryOutsideWindow) {
                _ = try tools.lookup(
                    AIAgentLookupQuery(interval: bad),
                    permission: permission(), in: context)
            }
        }
    }

    // MARK: - Lookup

    /// Date window, kind, source and text all compose — and the previews
    /// carry display data only.
    @Test func lookupFiltersDateKindSourceAndText() throws {
        let context = try makeContext()
        let (cash, bank, food, salary) = try seedBasics(in: context)
        // Inside the November window:
        seed(in: context, amount: 125_000, date: day(2026, 11, 10),
             note: "Ăn nhậu", account: cash)
        seed(in: context, date: day(2026, 11, 12),
             note: "GRAB FOOD", account: bank,
             needsReview: true, source: .wallet)
        seed(in: context, kind: .income, amount: 15_000_000,
             date: day(2026, 11, 15), note: "Lương tháng 11",
             account: bank, category: salary, source: .csv)
        seed(in: context, kind: .transfer, amount: 2_000_000,
             date: day(2026, 11, 18), account: cash, toAccount: bank)
        seed(in: context, amount: 95_000, date: day(2026, 11, 20),
             note: "Rule đã gán", account: bank,
             category: food, needsReview: true, source: .wallet)
        // Outside the window — never visible:
        seed(in: context, date: day(2026, 10, 31, 23),
             note: "Tháng trước", account: cash)
        seed(in: context, date: day(2026, 12, 1, 0),
             note: "Tháng sau", account: cash)
        try context.save()
        let tools = AIAgentLedgerTools()

        let all = try tools.lookup(permission: permission(), in: context)
        #expect(all.matches.map(\.preview.note)
            == ["Rule đã gán", "", "Lương tháng 11", "GRAB FOOD", "Ăn nhậu"])
        #expect(!all.truncated)
        #expect(all.scanned == 5)
        #expect(all.window == window)

        #expect(try tools.lookup(
            AIAgentLookupQuery(kind: .expense),
            permission: permission(), in: context
        ).matches.map(\.preview.note) == ["Rule đã gán", "GRAB FOOD", "Ăn nhậu"])

        #expect(try tools.lookup(
            AIAgentLookupQuery(kind: .transfer),
            permission: permission(), in: context
        ).matches.map(\.preview.note) == [""])

        #expect(try tools.lookup(
            AIAgentLookupQuery(source: .wallet),
            permission: permission(), in: context
        ).matches.map(\.preview.note) == ["Rule đã gán", "GRAB FOOD"])

        #expect(try tools.lookup(
            AIAgentLookupQuery(source: .csv),
            permission: permission(), in: context
        ).matches.map(\.preview.note) == ["Lương tháng 11"])

        #expect(try tools.lookup(
            AIAgentLookupQuery(source: .manual),
            permission: permission(), in: context
        ).matches.map(\.preview.note) == ["", "Ăn nhậu"])

        // Vietnamese folding — "an nhau" finds "Ăn nhậu".
        let folded = try tools.lookup(
            AIAgentLookupQuery(text: "an nhau"),
            permission: permission(), in: context)
        #expect(folded.matches.map(\.preview.note) == ["Ăn nhậu"])
        #expect(try tools.lookup(
            AIAgentLookupQuery(text: "grab"),
            permission: permission(), in: context
        ).matches.map(\.preview.note) == ["GRAB FOOD"])

        // A digits-only query substring-matches the amount like the
        // transactions list search — not the note.
        #expect(try tools.lookup(
            AIAgentLookupQuery(text: "125"),
            permission: permission(), in: context
        ).matches.map(\.preview.note) == ["Ăn nhậu"])

        #expect(try tools.lookup(
            AIAgentLookupQuery(minAmount: 1_000_000),
            permission: permission(), in: context
        ).matches.map(\.preview.note) == ["", "Lương tháng 11"])
        #expect(try tools.lookup(
            AIAgentLookupQuery(minAmount: 100_000, maxAmount: 500_000),
            permission: permission(), in: context
        ).matches.map(\.preview.note) == ["GRAB FOOD", "Ăn nhậu"])

        // Preview carries names and flags — never ids or provenance keys.
        let preview = try #require(
            all.matches.first { $0.preview.note == "GRAB FOOD" }?.preview)
        #expect(preview.source == .wallet)
        #expect(preview.needsReview && preview.unclassified)
        #expect(preview.accountName == "VPBank *1234")
        #expect(preview.accountKind == .bank)
        #expect(preview.categoryName == nil)
        #expect(preview.kind == .expense)
    }

    /// "Chưa phân loại" mirrors the list scope: non-transfer rows with
    /// no category OR still flagged needsReview — a transfer without a
    /// category is never in the queue.
    @Test func unclassifiedLookupMirrorsListScope() throws {
        let context = try makeContext()
        let (cash, bank, food, _) = try seedBasics(in: context)
        seed(in: context, date: day(2026, 11, 10), note: "No category",
             account: cash)
        seed(in: context, date: day(2026, 11, 11), note: "Pending rule",
             account: bank, category: food, needsReview: true,
             source: .wallet)
        seed(in: context, date: day(2026, 11, 12), note: "Classified",
             account: cash, category: food)
        seed(in: context, kind: .transfer, date: day(2026, 11, 13),
             account: cash, toAccount: bank)
        try context.save()

        let result = try AIAgentLedgerTools().lookup(
            AIAgentLookupQuery(unclassifiedOnly: true),
            permission: permission(), in: context)
        #expect(result.matches.map(\.preview.note)
            == ["Pending rule", "No category"])
        #expect(result.matches.allSatisfy { $0.preview.unclassified })
    }

    /// The result cap and the bounded scan are app-controlled: 55
    /// matching rows return `resultLimit` newest-first with `truncated`,
    /// and a shrunken scan bound shortens the search honestly.
    @Test func lookupCapsResultsAndMarksTruncation() throws {
        let context = try makeContext()
        let (cash, _, _, _) = try seedBasics(in: context)
        for index in 1...55 {
            seed(in: context, amount: Int64(index) * 10_000,
                 date: day(2026, 11, 1, 0)
                     .addingTimeInterval(TimeInterval(index * 60)),
                 note: "Row \(index)", account: cash)
        }
        try context.save()

        let capped = try AIAgentLedgerTools().lookup(
            permission: permission(), in: context)
        #expect(capped.matches.count == AIAgentLedgerTools.resultLimit)
        #expect(capped.truncated)
        #expect(capped.scanned == 55)
        // Newest first — row 55 was inserted last in the window.
        #expect(capped.matches.first?.preview.note == "Row 55")

        let tiny = try AIAgentLedgerTools(scanLimit: 5).lookup(
            permission: permission(), in: context)
        #expect(tiny.scanned == 5)
        #expect(tiny.truncated)
        #expect(tiny.matches.count == 5)

        let smallCap = try AIAgentLedgerTools(resultLimit: 3).lookup(
            permission: permission(), in: context)
        #expect(smallCap.matches.count == 3)
        #expect(smallCap.truncated)
    }

    // MARK: - Apply (setCategory through the mixed batch)

    /// The confirmed batch lands atomically on the same rows: only
    /// category, needsReview and updatedAt move — id, amount, date,
    /// accounts, business and external identity all survive.
    @Test func applyReassignsCategoryKeepingProvenanceAndIdentity() throws {
        let context = try makeContext()
        let (cash, bank, food, _) = try seedBasics(in: context)
        let business = Business(name: "Chạy ads")
        context.insert(business)
        let synced = seed(in: context, amount: 125_000,
                          date: day(2026, 11, 10), note: "GRAB FOOD",
                          account: bank, needsReview: true,
                          source: .wallet)
        let manual = seed(in: context, amount: 60_000,
                          date: day(2026, 11, 11), note: "Ăn trưa",
                          account: cash, business: business)
        try context.save()
        let syncedID = synced.id
        let syncedDate = synced.date
        let syncedUpdated = synced.updatedAt
        let tools = AIAgentLedgerTools()

        let looked = try tools.lookup(permission: permission(), in: context)
        let matches = looked.matches.filter {
            $0.original.id == synced.id || $0.original.id == manual.id
        }
        #expect(matches.count == 2)

        let summary = try tools.apply(
            matches.map { .setCategory(match: $0, category: food) },
            permission: permission(), in: context)
        #expect(summary.categorized == 2)

        // Same rows — same ids, same objects.
        #expect(synced.category?.id == food.id)
        #expect(manual.category?.id == food.id)
        #expect(!synced.needsReview && !manual.needsReview)
        #expect(synced.updatedAt > syncedUpdated)

        // Everything else is exactly as it was.
        #expect(synced.id == syncedID && synced.kind == .expense)
        #expect(synced.amount == 125_000 && synced.date == syncedDate)
        #expect(synced.note == "GRAB FOOD")
        #expect(synced.account?.id == bank.id)
        #expect(synced.externalSource == WalletSyncEngine.externalSource)
        #expect(synced.externalID == "w-1")
        #expect(manual.business?.id == business.id)
        #expect(try fetchAll(LedgerTransaction.self, in: context).count == 2)
        #expect(!context.hasChanges)
    }

    /// One batch may mix target categories — each row lands on its own
    /// category in the same atomic commit.
    @Test func applyLandsMixedCategoriesAtomically() throws {
        let context = try makeContext()
        let (cash, bank, food, salary) = try seedBasics(in: context)
        let other = LedgerCategory(name: "Di chuyển", kind: .expense)
        context.insert(other)
        let coffee = seed(in: context, amount: 40_000,
                          date: day(2026, 11, 10), note: "cf",
                          account: cash)
        let taxi = seed(in: context, amount: 150_000,
                        date: day(2026, 11, 11), note: "grab",
                        account: bank)
        let pay = seed(in: context, kind: .income, amount: 9_000_000,
                       date: day(2026, 11, 12), note: "lương",
                       account: bank)
        try context.save()
        let tools = AIAgentLedgerTools()
        let looked = try tools.lookup(permission: permission(), in: context)
        func match(_ row: LedgerTransaction) throws -> AIAgentLookupMatch {
            try #require(looked.matches.first { $0.original.id == row.id })
        }

        let summary = try tools.apply(
            [.setCategory(match: try match(coffee), category: food),
             .setCategory(match: try match(taxi), category: other),
             .setCategory(match: try match(pay), category: salary)],
            permission: permission(), in: context)
        #expect(summary.categorized == 3)
        #expect(coffee.category?.id == food.id)
        #expect(taxi.category?.id == other.id)
        #expect(pay.category?.id == salary.id)
        #expect(!context.hasChanges)
    }

    /// Applying to a pending-review row that already carries the same
    /// category is a real edit — it confirms the classification and
    /// clears the flag.
    @Test func applyOnPendingReviewSameCategoryConfirmsIt() throws {
        let context = try makeContext()
        let (cash, _, food, _) = try seedBasics(in: context)
        let row = seed(in: context, date: day(2026, 11, 10), note: "Rule",
                       account: cash, category: food, needsReview: true,
                       source: .wallet)
        try context.save()
        let tools = AIAgentLedgerTools()
        let looked = try tools.lookup(
            AIAgentLookupQuery(unclassifiedOnly: true),
            permission: permission(), in: context)
        let summary = try tools.apply(
            looked.matches.map { .setCategory(match: $0, category: food) },
            permission: permission(), in: context)
        #expect(summary.categorized == 1)
        #expect(row.category?.id == food.id)
        #expect(!row.needsReview)
    }

    /// Transfers, rent-linked rows and rows outside the granted window
    /// are never touched — and neither is anything else in the batch.
    @Test func applyRejectsIneligibleAndOutOfWindowRows() throws {
        let context = try makeContext()
        let (cash, bank, food, _) = try seedBasics(in: context)
        let transfer = seed(in: context, kind: .transfer, amount: 500_000,
                            date: day(2026, 11, 10),
                            account: cash, toAccount: bank)
        let rent = seed(in: context, date: day(2026, 11, 12),
                        account: bank)
        rent.rentalPeriod = day(2026, 11, 1)
        let outside = seed(in: context, date: day(2026, 11, 28),
                           account: cash)
        try context.save()
        let tools = AIAgentLedgerTools()
        let looked = try tools.lookup(permission: permission(), in: context)

        func match(_ row: LedgerTransaction) throws -> AIAgentLookupMatch {
            try #require(looked.matches.first {
                $0.original.id == row.id })
        }

        #expect(throws: AIAgentApplyError.action(
            0, .transactionNotEligible)) {
            _ = try tools.apply(
                [.setCategory(match: try match(transfer), category: food)],
                permission: permission(), in: context)
        }
        #expect(throws: AIAgentApplyError.action(
            0, .transactionNotEligible)) {
            _ = try tools.apply(
                [.setCategory(match: try match(rent), category: food)],
                permission: permission(), in: context)
        }

        // The same row confirmed under a narrower grant — the shrunken
        // window no longer covers its date.
        let narrower = permission(
            window: DateInterval(
                start: day(2026, 11, 1, 0), end: day(2026, 11, 20, 0)))
        #expect(throws: AIAgentApplyError.action(0, .rowOutsideWindow)) {
            _ = try tools.apply(
                [.setCategory(match: try match(outside), category: food)],
                permission: narrower, in: context)
        }
        #expect(transfer.category == nil)
        #expect(rent.category == nil)
        #expect(outside.category == nil)
        #expect(!context.hasChanges)
    }

    /// The category must be live, on this context and kind-matching —
    /// an income category on an expense batch fails the whole batch.
    @Test func applyRejectsBadCategories() throws {
        let context = try makeContext()
        let (cash, bank, food, salary) = try seedBasics(in: context)
        let archived = LedgerCategory(
            name: "Cũ", kind: .expense, isArchived: true)
        context.insert(archived)
        let expense = seed(in: context, date: day(2026, 11, 10),
                           account: cash)
        let income = seed(in: context, kind: .income,
                          date: day(2026, 11, 11), account: bank)
        try context.save()
        let tools = AIAgentLedgerTools()
        let looked = try tools.lookup(permission: permission(), in: context)

        func match(_ row: LedgerTransaction) throws -> AIAgentLookupMatch {
            try #require(looked.matches.first {
                $0.original.id == row.id })
        }

        // Wrong-kind category for the row.
        #expect(throws: AIAgentApplyError.action(0, .invalidCategory)) {
            _ = try tools.apply(
                [.setCategory(match: try match(expense), category: salary)],
                permission: permission(), in: context)
        }
        // A mixed batch dies whole — the valid expense stays untouched.
        #expect(throws: AIAgentApplyError.action(1, .invalidCategory)) {
            _ = try tools.apply(
                [.setCategory(match: try match(expense), category: food),
                 .setCategory(match: try match(income), category: food)],
                permission: permission(), in: context)
        }
        #expect(throws: AIAgentApplyError.action(0, .invalidCategory)) {
            _ = try tools.apply(
                [.setCategory(match: try match(expense), category: archived)],
                permission: permission(), in: context)
        }
        // A category object that never entered this context.
        #expect(throws: AIAgentApplyError.action(0, .invalidCategory)) {
            _ = try tools.apply(
                [.setCategory(
                    match: try match(expense),
                    category: LedgerCategory(name: "Bay", kind: .expense))],
                permission: permission(), in: context)
        }
        #expect(expense.category == nil && income.category == nil)
        #expect(!context.hasChanges)
    }

    /// The UI-level mirror exposes the same eligibility rule the apply
    /// enforces — transfers and rent-linked rows are out.
    @Test func eligibilityMirrorMatchesApplyGuards() throws {
        let context = try makeContext()
        let (cash, bank, _, _) = try seedBasics(in: context)
        let expense = LedgerTransaction(
            kind: .expense, amount: 100_000, account: cash)
        let income = LedgerTransaction(
            kind: .income, amount: 100_000, account: bank)
        let transfer = LedgerTransaction(
            kind: .transfer, amount: 100_000,
            account: cash, toAccount: bank)
        let rent = LedgerTransaction(
            kind: .expense, amount: 100_000, account: bank,
            rentalPeriod: day(2026, 11, 1))
        #expect(AIAgentLedgerTools.canEditCategory(of: expense))
        #expect(AIAgentLedgerTools.canEditCategory(of: income))
        #expect(!AIAgentLedgerTools.canEditCategory(of: transfer))
        #expect(!AIAgentLedgerTools.canEditCategory(of: rent))
        #expect(AIAgentLedgerTools.categoryKind(of: .income) == .income)
        #expect(AIAgentLedgerTools.categoryKind(of: .expense) == .expense)
        #expect(AIAgentLedgerTools.categoryKind(of: .transfer) == nil)
    }

    /// Every validation error carries a Vietnamese message the UI can
    /// show verbatim.
    @Test func errorsAreLocalizedInVietnamese() {
        let cases: [AIAgentError] = [
            .permissionDenied, .windowTooWide, .queryOutsideWindow,
            .rowOutsideWindow, .contextHasChanges, .emptyBatch,
            .duplicateTransaction, .staleTransaction,
            .transactionNotEligible, .invalidCategory, .noOpEdit,
            .saveFailed(URLError(.cannotConnectToHost)),
            .unparseableModelReply, .unsupportedTool, .malformedQuery,
            .unknownHandle, .invalidProposal,
            .tooManyActions, .invalidDraft, .invalidEdit,
        ]
        for error in cases {
            #expect(error.errorDescription?.isEmpty == false)
        }
        #expect(AIAgentError.staleTransaction.errorDescription
            == "Giao dịch đã thay đổi hoặc bị xoá — hãy tra cứu lại.")
    }

    // MARK: - Search-args parsing (AIAgentToolPlanner)

    /// A valid tool call maps onto the typed query: `to` is an inclusive
    /// day (the interval ends at the next day start) and every filter
    /// axis lands where the lookup expects it. The `args`/`arguments`/
    /// `parameters` spellings all parse.
    @Test func parseMapsArgsToTheTypedQuery() throws {
        for key in ["args", "arguments", "parameters"] {
            let query = try AIAgentToolPlanner.parse(
                """
                {"tool":"searchTransactions","\(key)":{"from":"2026-11-10",
                    "to":"2026-11-12","kind":"expense","source":"wallet",
                    "text":"grab","needsReview":true,
                    "minAmount":10000,"maxAmount":"200000"}}
                """,
                grantedWindow: window, calendar: calendar)
            #expect(query.kind == .expense)
            #expect(query.source == .wallet)
            #expect(query.text == "grab")
            #expect(query.unclassifiedOnly)
            #expect(query.minAmount == 10_000 && query.maxAmount == 200_000)
            let interval = try #require(query.interval)
            #expect(interval.start == day(2026, 11, 10, 0))
            #expect(interval.end == day(2026, 11, 13, 0))
        }
    }

    /// Wrong tool, non-dict args, unknown fields, bad dates, inverted
    /// ranges and bounds — every malformed reply fails before the read.
    @Test func parseRejectsWrongToolAndMalformedArgs() throws {
        // A different or missing tool name → not the allow-listed call.
        for reply in [
            #"{"tool":"deleteTransactions","args":{}}"#,
            #"{"args":{"kind":"expense"}}"#,
        ] {
            #expect(throws: AIAgentError.unsupportedTool) {
                _ = try AIAgentToolPlanner.parse(
                    reply, grantedWindow: window, calendar: calendar)
            }
        }
        // args must be an object; unknown fields are refused.
        for reply in [
            #"{"tool":"searchTransactions","args":[1,2]}"#,
            #"{"tool":"searchTransactions","args":{"account":"Tiền mặt"}}"#,
        ] {
            #expect(throws: AIAgentError.malformedQuery) {
                _ = try AIAgentToolPlanner.parse(
                    reply, grantedWindow: window, calendar: calendar)
            }
        }
        // Bad day strings and inverted ranges.
        for reply in [
            #"{"tool":"searchTransactions","args":{"from":"10/11/2026"}}"#,
            #"{"tool":"searchTransactions","args":{"from":"2026-13-01"}}"#,
            #"{"tool":"searchTransactions","args":{"from":"2026-11-20","to":"2026-11-10"}}"#,
            #"{"tool":"searchTransactions","args":{"to":"hôm qua"}}"#,
        ] {
            #expect(throws: AIAgentError.malformedQuery) {
                _ = try AIAgentToolPlanner.parse(
                    reply, grantedWindow: window, calendar: calendar)
            }
        }
        // Inverted/negative bounds and a boolean-as-amount.
        for reply in [
            #"{"tool":"searchTransactions","args":{"minAmount":500,"maxAmount":100}}"#,
            #"{"tool":"searchTransactions","args":{"minAmount":-5}}"#,
            #"{"tool":"searchTransactions","args":{"maxAmount":true}}"#,
        ] {
            #expect(throws: AIAgentError.malformedQuery) {
                _ = try AIAgentToolPlanner.parse(
                    reply, grantedWindow: window, calendar: calendar)
            }
        }
        // Unknown enum values.
        for reply in [
            #"{"tool":"searchTransactions","args":{"kind":"saving"}}"#,
            #"{"tool":"searchTransactions","args":{"source":"bank"}}"#,
            #"{"tool":"searchTransactions","args":{"needsReview":"yes"}}"#,
        ] {
            #expect(throws: AIAgentError.malformedQuery) {
                _ = try AIAgentToolPlanner.parse(
                    reply, grantedWindow: window, calendar: calendar)
            }
        }
        // Overlong search text.
        let overlong = """
        {"tool":"searchTransactions","args":{"text":"\(String(repeating: "a", count: 200))"}}
        """
        #expect(throws: AIAgentError.malformedQuery) {
            _ = try AIAgentToolPlanner.parse(
                overlong, grantedWindow: window, calendar: calendar)
        }
        // A day range escaping the grant — refused, not clipped.
        for reply in [
            #"{"tool":"searchTransactions","args":{"from":"2026-10-01"}}"#,
            #"{"tool":"searchTransactions","args":{"to":"2026-12-15"}}"#,
            #"{"tool":"searchTransactions","args":{"from":"2027-01-05","to":"2027-01-10"}}"#,
        ] {
            #expect(throws: AIAgentError.queryOutsideWindow) {
                _ = try AIAgentToolPlanner.parse(
                    reply, grantedWindow: window, calendar: calendar)
            }
        }
    }

    /// A reply with no usable JSON at all is a parse failure.
    @Test func parseRejectsNonJSON() throws {
        #expect(throws: AIAgentError.unparseableModelReply) {
            _ = try AIAgentToolPlanner.parse(
                "Xin lỗi, tôi không hiểu.",
                grantedWindow: window, calendar: calendar)
        }
        // An empty args object parses — every axis defaults to "all".
        let query = try AIAgentToolPlanner.parse(
            #"{"tool":"searchTransactions","args":{}}"#,
            grantedWindow: window, calendar: calendar)
        #expect(query.interval == nil && query.kind == nil)
        #expect(query.text.isEmpty && !query.unclassifiedOnly)
    }
}
