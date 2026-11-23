import Testing
import Foundation
import SwiftData
import UIKit
import FinanceCore
@testable import AMFinance

/// "AI nhập chi tiêu" — the `AICaptureModel` state machine, extraction →
/// `TransactionDraft` mapping, the last-used-account fallback, the
/// auto-save rule and its undo window, all driven by a fake
/// `AICaptureServicing` so no HTTP is involved.
@MainActor
struct AICaptureTests {

    // MARK: - Scaffolding

    /// The fake provider: every `complete` runs the injected handler.
    /// `@unchecked Sendable` because the handler may capture non-Sendable
    /// test state (errors, boxes); tests stay on the main actor.
    private struct FakeService: AICaptureServicing, @unchecked Sendable {
        var handler: (AIRequest) async throws -> AIResponse

        func complete(_ request: AIRequest) async throws -> AIResponse {
            try await handler(request)
        }
    }

    /// Records the last request the model sent through the service.
    private final class RequestBox: @unchecked Sendable {
        private(set) var requests: [AIRequest] = []
        func record(_ request: AIRequest) { requests.append(request) }
    }

    private struct Fixture {
        var context: ModelContext
        var catalog: AICaptureCatalog
        var cash: Account
        var bank: Account
        var card: Account
        var food: LedgerCategory
        var salary: LedgerCategory
        var business: Business
    }

    private func makeContext() throws -> ModelContext {
        ModelContext(try AppModelContainer.make(inMemory: true))
    }

    private func makeDefaults() throws -> UserDefaults {
        try #require(UserDefaults(
            suiteName: "AICaptureTests.\(UUID().uuidString)"))
    }

    private func makeFixture() throws -> Fixture {
        let context = try makeContext()
        let cash = Account(
            name: "Tiền mặt", kind: .cash, openingBalance: 1_000_000)
        let bank = Account(
            name: "ACB x123", kind: .bank, openingBalance: 5_000_000)
        let card = Account(name: "Thẻ VPBank", kind: .creditCard)
        let food = LedgerCategory(name: "Ăn uống", kind: .expense)
        let salary = LedgerCategory(name: "Lương & thù lao", kind: .income)
        let business = Business(name: "Căn hộ dịch vụ")
        for account in [cash, bank, card] { context.insert(account) }
        context.insert(food)
        context.insert(salary)
        context.insert(business)
        try context.save()
        return Fixture(
            context: context,
            catalog: AICaptureCatalog(
                categories: [food, salary],
                accounts: [cash, bank, card],
                businesses: [business]),
            cash: cash, bank: bank, card: card,
            food: food, salary: salary, business: business)
    }

    private func makeModel(
        fixture: Fixture,
        defaults: UserDefaults,
        handler: @escaping (AIRequest) async throws -> AIResponse,
        autoSave: Bool = false,
        now: @escaping () -> Date = { Date(timeIntervalSince1970: 1_800_000_000) }
    ) -> AICaptureModel {
        let service = FakeService(handler: handler)
        return AICaptureModel(
            makeService: { service },
            catalog: fixture.catalog,
            defaults: defaults,
            autoSaveEnabled: autoSave,
            now: now)
    }

    private func makeModel(
        fixture: Fixture,
        defaults: UserDefaults,
        reply: String,
        autoSave: Bool = false,
        now: @escaping () -> Date = { Date(timeIntervalSince1970: 1_800_000_000) }
    ) -> AICaptureModel {
        makeModel(
            fixture: fixture, defaults: defaults,
            handler: { _ in
                AIResponse(
                    text: reply, model: "fake",
                    inputTokens: nil, outputTokens: nil)
            },
            autoSave: autoSave, now: now)
    }

    private func tinyImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { _ in }
    }

    private func transactions(in context: ModelContext) throws -> [LedgerTransaction] {
        try context.fetch(FetchDescriptor<LedgerTransaction>())
    }

    private func failedMessage(of model: AICaptureModel) -> String? {
        if case .failed(let message) = model.phase { return message }
        return nil
    }

    // MARK: - Analyze → review

    @Test func twoItemReplyBecomesTwoReviewCards() async throws {
        let fixture = try makeFixture()
        let defaults = try makeDefaults()
        let model = makeModel(fixture: fixture, defaults: defaults, reply: """
        {"items":[
          {"kind":"expense","amount":85000,"note":"Ăn trưa",
           "category":"Ăn uống","account":"Tiền mặt","confidence":0.9},
          {"kind":"income","amount":"2tr","note":"Lương",
           "category":"Lương & thù lao","account":"ACB x123","confidence":0.8}
        ]}
        """)
        model.prompt = "ăn trưa 85k tiền mặt, lương 2tr về ACB"

        await model.performAnalysis(context: fixture.context)

        #expect(model.phase == .review)
        #expect(model.items.count == 2)
        let first = try #require(model.items.first)
        #expect(first.kind == .expense)
        #expect(first.amount == 85_000)
        #expect(first.categoryID == fixture.food.id)
        #expect(first.accountID == fixture.cash.id)
        let second = model.items[1]
        #expect(second.kind == .income)
        #expect(second.amount == 2_000_000)
        #expect(second.categoryID == fixture.salary.id)
        #expect(second.accountID == fixture.bank.id)
    }

    @Test func requestCarriesPromptImagesAndCatalogInSystemPrompt() async throws {
        let fixture = try makeFixture()
        let defaults = try makeDefaults()
        let box = RequestBox()
        let model = makeModel(fixture: fixture, defaults: defaults) { request in
            box.record(request)
            return AIResponse(
                text: #"{"items":[]}"#, model: "fake",
                inputTokens: nil, outputTokens: nil)
        }
        model.prompt = "đọc bill giúp tôi"
        model.addImage(tinyImage())

        await model.performAnalysis(context: fixture.context)

        let request = try #require(box.requests.first)
        #expect(request.messages.count == 1)
        #expect(request.messages[0].text == "đọc bill giúp tôi")
        // The bill photo was prepared and attached to the request…
        #expect(request.messages[0].images.count == 1)
        // …and dropped once the request was answered.
        #expect(model.images.isEmpty)
        let system = try #require(request.system)
        #expect(system.contains("Ăn uống"))
        #expect(system.contains("Lương & thù lao"))
        #expect(system.contains("Tiền mặt"))
        #expect(system.contains("ACB x123"))
        #expect(system.contains("Căn hộ dịch vụ"))
        #expect(request.jsonMode)
    }

    @Test func unmatchedCategoryStaysValidButFlagged() async throws {
        let fixture = try makeFixture()
        let defaults = try makeDefaults()
        let model = makeModel(fixture: fixture, defaults: defaults, reply: """
        {"items":[{"kind":"expense","amount":10000,
          "category":"Tàu vũ trụ","account":"Tiền mặt","confidence":0.8}]}
        """)
        model.prompt = "x"

        await model.performAnalysis(context: fixture.context)

        let item = try #require(model.items.first)
        #expect(item.categoryID == nil)
        #expect(item.warnings.contains { $0.contains("không khớp") })
        // Flagged, but the missing category never blocks saving.
        #expect(item.isValid(in: fixture.catalog))
        #expect(model.canSaveAll)
    }

    @Test func missingAccountFallsBackToLastUsed() async throws {
        let fixture = try makeFixture()
        let defaults = try makeDefaults()
        defaults.set(fixture.bank.id.uuidString,
                     forKey: DataResetService.lastUsedAccountDefaultsKey)
        let model = makeModel(fixture: fixture, defaults: defaults, reply: """
        {"items":[{"kind":"expense","amount":50000,"confidence":0.9}]}
        """)
        model.prompt = "ăn 50k"

        await model.performAnalysis(context: fixture.context)

        #expect(model.items.first?.accountID == fixture.bank.id)
        #expect(model.items.first?.isValid(in: fixture.catalog) == true)
    }

    @Test func fallbackIgnoresUnknownLastUsedAccount() async throws {
        let fixture = try makeFixture()
        let defaults = try makeDefaults()
        defaults.set(UUID().uuidString,
                     forKey: DataResetService.lastUsedAccountDefaultsKey)
        let model = makeModel(fixture: fixture, defaults: defaults, reply: """
        {"items":[{"kind":"expense","amount":50000,"confidence":0.9}]}
        """)
        model.prompt = "x"

        await model.performAnalysis(context: fixture.context)

        let item = try #require(model.items.first)
        #expect(item.accountID == nil)
        #expect(!item.isValid(in: fixture.catalog))
    }

    // MARK: - Saving

    @Test func saveAllInsertsRowsAndMovesBalances() async throws {
        let fixture = try makeFixture()
        let defaults = try makeDefaults()
        let model = makeModel(fixture: fixture, defaults: defaults, reply: """
        {"items":[
          {"kind":"expense","amount":85000,"account":"Tiền mặt","confidence":0.9},
          {"kind":"expense","amount":50000,"account":"Tiền mặt","confidence":0.8},
          {"kind":"income","amount":200000,"account":"ACB x123","confidence":0.9}
        ]}
        """)
        model.prompt = "x"
        await model.performAnalysis(context: fixture.context)

        let inserted = try model.saveAll(context: fixture.context)

        #expect(inserted == 3)
        #expect(model.phase == .saved)
        #expect(!model.savedAutomatically)
        #expect(model.undoDeadline == nil)
        #expect(fixture.cash.balance == 1_000_000 - 135_000)
        #expect(fixture.bank.balance == 5_000_000 + 200_000)
        #expect(try transactions(in: fixture.context).count == 3)
        // The last saved source account becomes the next fallback.
        #expect(defaults.string(
            forKey: DataResetService.lastUsedAccountDefaultsKey)
            == fixture.bank.id.uuidString)
    }

    @Test func invalidAmountBlocksThatItemButNotTheRest() async throws {
        let fixture = try makeFixture()
        let defaults = try makeDefaults()
        let model = makeModel(fixture: fixture, defaults: defaults, reply: """
        {"items":[
          {"kind":"expense","amount":85000,"account":"Tiền mặt","confidence":0.9},
          {"kind":"expense","amount":50000,"account":"Tiền mặt","confidence":0.9}
        ]}
        """)
        model.prompt = "x"
        await model.performAnalysis(context: fixture.context)

        model.items[0].amount = 0
        #expect(!model.items[0].isValid(in: fixture.catalog))
        #expect(!model.canSaveAll)

        // saveAll skips the invalid item — it is never persisted.
        let inserted = try model.saveAll(context: fixture.context)
        #expect(inserted == 1)
        let rows = try transactions(in: fixture.context)
        #expect(rows.count == 1)
        #expect(rows.first?.amount == 50_000)
        #expect(fixture.cash.balance == 950_000)
    }

    @Test func transferItemMapsSourceAndDestination() async throws {
        let fixture = try makeFixture()
        let defaults = try makeDefaults()
        let model = makeModel(fixture: fixture, defaults: defaults, reply: """
        {"items":[{"kind":"transfer","amount":500000,
          "account":"Tiền mặt","toAccount":"ACB x123","confidence":0.95}]}
        """)
        model.prompt = "chuyển 500k từ tiền mặt sang ACB"
        await model.performAnalysis(context: fixture.context)

        let item = try #require(model.items.first)
        #expect(item.kind == .transfer)
        #expect(item.accountID == fixture.cash.id)
        #expect(item.toAccountID == fixture.bank.id)

        let draft = item.makeDraft(in: fixture.catalog)
        #expect(draft.account?.id == fixture.cash.id)
        #expect(draft.toAccount?.id == fixture.bank.id)
        #expect(draft.isValid)

        _ = try model.saveAll(context: fixture.context)
        #expect(fixture.cash.balance == 500_000)
        #expect(fixture.bank.balance == 5_500_000)
        let row = try #require(transactions(in: fixture.context).first)
        #expect(row.kind == .transfer)
        #expect(row.toAccount?.id == fixture.bank.id)
        #expect(row.category == nil)
    }

    @Test func kindSwitchNormalizesItemFields() async throws {
        let fixture = try makeFixture()
        var item = AICaptureItem(draft: AIDraftTransaction(
            kind: .expense, amount: 10_000, date: .now, note: "",
            categoryID: fixture.food.id, accountID: fixture.cash.id,
            toAccountID: nil, businessID: fixture.business.id,
            confidence: 0.9, warnings: []))

        // Expense → transfer drops category and business.
        item.setKind(.transfer, catalog: fixture.catalog)
        #expect(item.categoryID == nil)
        #expect(item.businessID == nil)

        // Transfer → income drops the destination; a category of the wrong
        // kind is then cleared on the next switch.
        item.toAccountID = fixture.bank.id
        item.setKind(.income, catalog: fixture.catalog)
        #expect(item.toAccountID == nil)
        item.categoryID = fixture.food.id
        item.setKind(.income, catalog: fixture.catalog)
        #expect(item.categoryID == fixture.food.id) // no-op keeps the field
        #expect(!item.isValid(in: fixture.catalog)) // expense category on income
        item.categoryID = fixture.salary.id
        #expect(item.isValid(in: fixture.catalog))
    }

    // MARK: - Auto-save

    @Test func autoSaveTriggersWhenAllItemsValidAndConfident() async throws {
        let fixture = try makeFixture()
        let defaults = try makeDefaults()
        let model = makeModel(
            fixture: fixture, defaults: defaults, reply: """
            {"items":[
              {"kind":"expense","amount":85000,"account":"Tiền mặt",
               "category":"Ăn uống","confidence":0.95},
              {"kind":"income","amount":100000,"account":"ACB x123",
               "confidence":0.9}
            ]}
            """, autoSave: true)
        model.prompt = "x"

        await model.performAnalysis(context: fixture.context)

        #expect(model.phase == .saved)
        #expect(model.savedAutomatically)
        #expect(model.undoDeadline != nil)
        #expect(try transactions(in: fixture.context).count == 2)
        #expect(fixture.cash.balance == 915_000)
        #expect(fixture.bank.balance == 5_100_000)
    }

    @Test func autoSaveSkippedWhenAnyItemBelowConfidence() async throws {
        let fixture = try makeFixture()
        let defaults = try makeDefaults()
        let model = makeModel(
            fixture: fixture, defaults: defaults, reply: """
            {"items":[
              {"kind":"expense","amount":85000,"account":"Tiền mặt",
               "confidence":0.95},
              {"kind":"expense","amount":10000,"account":"Tiền mặt",
               "confidence":0.8}
            ]}
            """, autoSave: true)
        model.prompt = "x"

        await model.performAnalysis(context: fixture.context)

        #expect(model.phase == .review)
        #expect(!model.savedAutomatically)
        #expect(try transactions(in: fixture.context).isEmpty)
    }

    @Test func autoSaveSkippedWhenItemInvalidOrSettingOff() async throws {
        let fixture = try makeFixture()
        let defaults = try makeDefaults()

        // Invalid: no account anywhere → review, nothing inserted.
        let invalid = makeModel(
            fixture: fixture, defaults: defaults, reply: """
            {"items":[{"kind":"expense","amount":85000,"confidence":0.99}]}
            """, autoSave: true)
        invalid.prompt = "x"
        await invalid.performAnalysis(context: fixture.context)
        #expect(invalid.phase == .review)
        #expect(try transactions(in: fixture.context).isEmpty)

        // Setting off: identical confident items stay on the review screen.
        let manual = makeModel(
            fixture: fixture, defaults: defaults, reply: """
            {"items":[{"kind":"expense","amount":85000,"account":"Tiền mặt",
              "confidence":0.99}]}
            """, autoSave: false)
        manual.prompt = "x"
        await manual.performAnalysis(context: fixture.context)
        #expect(manual.phase == .review)
        #expect(try transactions(in: fixture.context).isEmpty)
    }

    // MARK: - Undo

    @Test func undoInsideWindowDeletesTheBatchAndReturnsToReview() async throws {
        let fixture = try makeFixture()
        let defaults = try makeDefaults()
        let model = makeModel(
            fixture: fixture, defaults: defaults, reply: """
            {"items":[{"kind":"expense","amount":85000,"account":"Tiền mặt",
              "confidence":0.95}]}
            """, autoSave: true)
        model.prompt = "x"
        await model.performAnalysis(context: fixture.context)
        #expect(model.phase == .saved)
        #expect(fixture.cash.balance == 915_000)

        model.undoSaved(context: fixture.context)

        #expect(model.phase == .review)
        #expect(model.savedTransactions.isEmpty)
        #expect(try transactions(in: fixture.context).isEmpty)
        #expect(fixture.cash.balance == 1_000_000)
        // The extracted item survives — the owner can still fix and save.
        #expect(model.items.count == 1)
    }

    @Test func undoAfterWindowDoesNothing() async throws {
        let fixture = try makeFixture()
        let defaults = try makeDefaults()
        var current = Date(timeIntervalSince1970: 1_800_000_000)
        let model = makeModel(
            fixture: fixture, defaults: defaults,
            reply: """
            {"items":[{"kind":"expense","amount":85000,"account":"Tiền mặt",
              "confidence":0.95}]}
            """,
            autoSave: true, now: { current })
        model.prompt = "x"
        await model.performAnalysis(context: fixture.context)
        #expect(model.phase == .saved)

        current = current.addingTimeInterval(AICaptureModel.undoWindow + 1)
        model.undoSaved(context: fixture.context)

        #expect(model.phase == .saved)
        #expect(try transactions(in: fixture.context).count == 1)
    }

    // MARK: - Cancel & failure

    @Test func cancelDuringAnalysisReturnsToIdleKeepingInputs() async throws {
        let fixture = try makeFixture()
        let defaults = try makeDefaults()
        let model = makeModel(fixture: fixture, defaults: defaults) { _ in
            try await Task.sleep(for: .seconds(300))
            return AIResponse(
                text: #"{"items":[]}"#, model: "fake",
                inputTokens: nil, outputTokens: nil)
        }
        model.prompt = "ăn trưa 85k"
        model.addImage(tinyImage())

        model.startAnalysis(context: fixture.context)
        let task = try #require(model.analysisTask)
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.phase == .analyzing)

        model.cancelAnalysis()
        await task.value

        #expect(model.phase == .idle)
        #expect(model.prompt == "ăn trưa 85k")
        #expect(model.images.count == 1)
        #expect(model.analysisTask == nil)
    }

    @Test func providerErrorKeepsInputsAndShowsRetry() async throws {
        let fixture = try makeFixture()
        let defaults = try makeDefaults()
        let model = makeModel(fixture: fixture, defaults: defaults) { _ in
            throw AIError.offline
        }
        model.prompt = "ăn trưa 85k"
        model.addImage(tinyImage())

        await model.performAnalysis(context: fixture.context)

        let message = try #require(failedMessage(of: model))
        #expect(message == AIError.offline.errorDescription)
        #expect(model.prompt == "ăn trưa 85k")
        #expect(model.images.count == 1)
        #expect(model.canAnalyze) // retry is possible with the same inputs
    }

    @Test func missingProviderFailsFast() async throws {
        let fixture = try makeFixture()
        let defaults = try makeDefaults()
        let model = AICaptureModel(
            makeService: { throw AIError.notConfigured },
            catalog: fixture.catalog,
            defaults: defaults)
        model.prompt = "x"

        await model.performAnalysis(context: fixture.context)

        #expect(failedMessage(of: model)
            == AIError.notConfigured.errorDescription)
        #expect(model.analysisTask == nil)
    }

    // MARK: - Nothing extracted

    @Test func modelMessageShownWhenNothingExtracted() async throws {
        let fixture = try makeFixture()
        let defaults = try makeDefaults()
        let model = makeModel(
            fixture: fixture, defaults: defaults,
            reply: #"{"items":[],"message":"Ảnh mờ quá — không đọc được."}"#)
        model.prompt = "đọc bill"

        await model.performAnalysis(context: fixture.context)

        #expect(model.phase == .review)
        #expect(model.items.isEmpty)
        #expect(model.modelMessage == "Ảnh mờ quá — không đọc được.")
        #expect(!model.canSaveAll)

        // "Nhập lại" returns to the input with the prompt intact.
        model.backToInput()
        #expect(model.phase == .idle)
        #expect(model.prompt == "đọc bill")
    }

    @Test func defaultMessageWhenReplyHasNoItemsAndNoMessage() async throws {
        let fixture = try makeFixture()
        let defaults = try makeDefaults()
        let model = makeModel(
            fixture: fixture, defaults: defaults, reply: #"{"items":[]}"#)
        model.prompt = "???"

        await model.performAnalysis(context: fixture.context)

        #expect(model.phase == .review)
        #expect(model.items.isEmpty)
        #expect(model.modelMessage != nil)
    }

    // MARK: - Mealtime context

    /// 2026-11-24 00:30 UTC = 07:30 in Vietnam — inside bữa sáng.
    private var breakfastUTC: Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        return utc.date(from: DateComponents(
            year: 2026, month: 11, day: 24, hour: 0, minute: 30))!
    }

    @Test func captureCarriesMealtimeContextAndOneInstant() async throws {
        let fixture = try makeFixture()
        let defaults = try makeDefaults()
        let box = RequestBox()
        var nowCalls = 0
        let model = makeModel(
            fixture: fixture, defaults: defaults,
            handler: { request in
                box.record(request)
                return AIResponse(
                    text: """
                    {"items":[{"kind":"expense","amount":50000,
                      "note":"Phở sáng","category":"Ăn uống",
                      "account":"Tiền mặt","confidence":0.9}]}
                    """,
                    model: "fake", inputTokens: nil, outputTokens: nil)
            },
            now: {
                defer { nowCalls += 1 }
                // A second reading would land an hour later — one shared
                // capture instant keeps prompt and parse aligned.
                return breakfastUTC.addingTimeInterval(
                    TimeInterval(nowCalls) * 3600)
            })
        model.prompt = "đá tô phở 50K"

        await model.performAnalysis(context: fixture.context)

        #expect(model.phase == .review)
        #expect(nowCalls == 1)
        let item = try #require(model.items.first)
        #expect(item.amount == 50_000)
        #expect(item.note == "Phở sáng")
        #expect(item.categoryID == fixture.food.id)
        #expect(item.accountID == fixture.cash.id)
        // The missing date defaults to the same instant the prompt
        // announced — not a second, later clock read.
        #expect(item.date == breakfastUTC)
        let system = try #require(box.requests.first?.system)
        #expect(system.contains("07:30"))
        #expect(system.contains("đang trong bữa sáng"))
        #expect(system.contains("05:00–10:59"))
    }

    // MARK: - Rejections

    @Test func rejectedRowsAreSurfacedForDisplay() async throws {
        let fixture = try makeFixture()
        let defaults = try makeDefaults()
        let model = makeModel(fixture: fixture, defaults: defaults, reply: """
        {"items":[
          {"kind":"expense","amount":"không rõ"},
          {"kind":"expense","amount":50000,"account":"Tiền mặt","confidence":0.9}
        ]}
        """)
        model.prompt = "x"

        await model.performAnalysis(context: fixture.context)

        #expect(model.phase == .review)
        #expect(model.items.count == 1)
        #expect(model.rejections.count == 1)
        #expect(model.rejections.first?.index == 0)
    }
}
