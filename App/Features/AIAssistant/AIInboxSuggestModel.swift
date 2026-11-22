import Foundation
import Observation
import SwiftData
import FinanceCore

/// One pending `needsReview` transaction, flattened so the model never
/// holds SwiftData objects. `signedAmount` follows the bank convention
/// `AIBankRow` expects: negative = money out.
struct AIInboxPendingInput: Equatable, Sendable, Identifiable {
    var transactionID: UUID
    var kind: TransactionKind
    var signedAmount: Int64
    var note: String
    var date: Date
    var accountName: String?

    var id: UUID { transactionID }

    init(
        transactionID: UUID,
        kind: TransactionKind,
        signedAmount: Int64,
        note: String,
        date: Date,
        accountName: String? = nil
    ) {
        self.transactionID = transactionID
        self.kind = kind
        self.signedAmount = signedAmount
        self.note = note
        self.date = date
        self.accountName = accountName
    }
}

/// The names the model may reference — built once from the live category
/// and business lists and reused for the prompt and for resolving the
/// ids the reply names.
struct AIInboxVocabulary: Sendable {
    var expenseCategories: [(id: UUID, name: String)] = []
    var incomeCategories: [(id: UUID, name: String)] = []
    var businesses: [(id: UUID, name: String)] = []

    var expenseIndex: AINameIndex { AINameIndex(expenseCategories) }
    var incomeIndex: AINameIndex { AINameIndex(incomeCategories) }
    var businessIndex: AINameIndex { AINameIndex(businesses) }

    /// Display name for an id the model returned, whichever list it came
    /// from.
    func name(for id: UUID) -> String? {
        expenseCategories.first { $0.id == id }?.name
            ?? incomeCategories.first { $0.id == id }?.name
            ?? businesses.first { $0.id == id }?.name
    }
}

/// One row of the suggestion sheet: the pending transaction plus what the
/// model suggested for it and where the user left it.
struct AIInboxSuggestRow: Equatable, Identifiable, Sendable {
    enum Status: Equatable, Sendable {
        /// Awaiting the user's decision (suggestion may still be nil
        /// while the batch is in flight or the model found nothing).
        case pending
        /// Accepted — the transaction was updated and saved.
        case accepted
        /// The model says internal transfer: flagged, but only the
        /// existing conversion flow may actually convert it.
        case transferMarked
        /// The model ran and offered nothing for this row.
        case noSuggestion
    }

    var input: AIInboxPendingInput
    var suggestion: AICategorizationSuggestion?
    /// Resolved display name of the suggestion target, when it exists.
    var targetName: String?
    var status: Status = .pending

    var id: UUID { input.transactionID }

    /// Absolute đồng magnitude for `AmountText`.
    var amount: Int64 {
        input.signedAmount == .min ? .max : abs(input.signedAmount)
    }
}

/// Drives the "gợi ý phân loại" sheet: batches the pending rows through
/// `AICategorization`, tracks per-row state, and applies accepted
/// suggestions to the `ModelContext` in single saves. `@MainActor` so the
/// context mutations stay where every other feature does them; the fake
/// client seam (`AIChatClientProtocol`) keeps tests off the network.
@MainActor @Observable
final class AIInboxSuggestModel {
    /// Pending rows per model call.
    static let batchSize = 40
    /// Confidence floor for "Chấp nhận tất cả gợi ý tin cậy cao".
    static let highConfidenceThreshold = 0.8

    /// Where the run stands. `failed` carries the Vietnamese message to
    /// show inline; a new `run` clears it.
    enum Phase: Equatable {
        case idle
        case running(done: Int, total: Int)
        case finished
        case failed(String)
    }

    private(set) var rows: [AIInboxSuggestRow] = []
    private(set) var phase: Phase = .idle
    /// Suggestions actually committed (accept, change, transfer
    /// conversion) — shown in the toolbar summary.
    private(set) var appliedCount = 0

    private let injectedClient: (any AIChatClientProtocol)?
    private let store: AIProviderStore
    private var runTask: Task<Void, Never>?

    init(
        client: (any AIChatClientProtocol)? = nil,
        store: AIProviderStore = AIProviderStore()
    ) {
        self.injectedClient = client
        self.store = store
    }

    /// The injected fake first, else the configured provider's client.
    var resolvedClient: (any AIChatClientProtocol)? {
        injectedClient ?? (try? store.makeClient())
    }

    var isConfigured: Bool { resolvedClient != nil }

    // MARK: - Running

    /// Rebuilds the row list from `pending` and streams it through the
    /// model in `batchSize` batches. Cancels any in-flight run first.
    /// Rows the model never mentions end up `.noSuggestion`.
    func run(
        pending: [AIInboxPendingInput],
        vocabulary: AIInboxVocabulary
    ) {
        runTask?.cancel()
        guard let client = resolvedClient else {
            phase = .failed(AIError.notConfigured.localizedDescription)
            return
        }
        rows = pending.map { AIInboxSuggestRow(input: $0) }
        appliedCount = 0
        let batches = Self.batches(of: Self.batchSize, rows: rows)
        phase = .running(done: 0, total: batches.count)
        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                for (index, batch) in batches.enumerated() {
                    try Task.checkCancellation()
                    let bankRows = batch.map {
                        AIBankRow(
                            id: $0.id.uuidString,
                            signedAmount: $0.input.signedAmount,
                            note: $0.input.note)
                    }
                    let request = AIRequest(
                        system: AICategorization.systemPrompt(
                            expenseCategories: vocabulary.expenseCategories.map(\.name),
                            incomeCategories: vocabulary.incomeCategories.map(\.name),
                            businesses: vocabulary.businesses.map(\.name)),
                        messages: [AIMessage(
                            role: .user,
                            text: AICategorization.userPrompt(rows: bankRows))],
                        jsonMode: true)
                    let response = try await client.complete(request)
                    try Task.checkCancellation()
                    let parsed = AICategorization.parse(
                        response.text,
                        validIDs: Set(bankRows.map(\.id)),
                        expenseCategories: vocabulary.expenseIndex,
                        incomeCategories: vocabulary.incomeIndex,
                        businesses: vocabulary.businessIndex)
                    merge(parsed, batch: batch, vocabulary: vocabulary)
                    phase = .running(done: index + 1, total: batches.count)
                }
                phase = .finished
            } catch is CancellationError {
                phase = .idle
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Stops the in-flight run. Rows keep their state; nothing more is
    /// applied.
    func cancel() {
        runTask?.cancel()
        runTask = nil
        if case .running = phase { phase = .idle }
    }

    /// Dismisses the inline error — the view's "Bỏ qua lỗi" button.
    func clearError() {
        if case .failed = phase { phase = .idle }
    }

    // MARK: - Batching

    /// `[T]` sliced into consecutive chunks of `size` — the rows keep
    /// their order (newest first, as the caller supplied them).
    static func batches<T>(of size: Int, rows: [T]) -> [[T]] {
        guard size > 0 else { return rows.isEmpty ? [] : [rows] }
        var result: [[T]] = []
        result.reserveCapacity(rows.count / size + 1)
        var index = rows.startIndex
        while index < rows.endIndex {
            let end = rows.index(index, offsetBy: size, limitedBy: rows.endIndex)
                ?? rows.endIndex
            result.append(Array(rows[index..<end]))
            index = end
        }
        return result
    }

    // MARK: - Applying

    /// Accepts the model's suggestion for one row: sets category or
    /// business and clears `needsReview`, then saves once. An
    /// internal-transfer suggestion only marks the row — the view opens
    /// the existing conversion flow for it.
    @discardableResult
    func accept(
        _ id: UUID,
        in context: ModelContext,
        transactions: [UUID: LedgerTransaction],
        categories: [UUID: LedgerCategory],
        businesses: [UUID: Business]
    ) -> Bool {
        guard let index = rows.firstIndex(where: { $0.id == id }),
              let suggestion = rows[index].suggestion,
              rows[index].status == .pending,
              let transaction = transactions[id]
        else { return false }
        return apply(
            suggestion.target, toRowAt: index, transaction: transaction,
            in: context, categories: categories, businesses: businesses,
            save: true)
    }

    /// The "Đổi" flow: the user picked the target explicitly. Saves once.
    @discardableResult
    func change(
        _ id: UUID,
        to target: AICategorizationSuggestion.Target,
        in context: ModelContext,
        transactions: [UUID: LedgerTransaction],
        categories: [UUID: LedgerCategory],
        businesses: [UUID: Business]
    ) -> Bool {
        guard let index = rows.firstIndex(where: { $0.id == id }),
              let transaction = transactions[id],
              rows[index].status == .pending || rows[index].status == .noSuggestion
        else { return false }
        return apply(
            target, toRowAt: index, transaction: transaction,
            in: context, categories: categories, businesses: businesses,
            save: true)
    }

    /// Applies every pending suggestion at or above
    /// `highConfidenceThreshold` in a single save. Returns how many rows
    /// changed (transfer-marked rows count — their status moved).
    @discardableResult
    func acceptAllHighConfidence(
        in context: ModelContext,
        transactions: [UUID: LedgerTransaction],
        categories: [UUID: LedgerCategory],
        businesses: [UUID: Business]
    ) -> Int {
        var applied = 0
        for index in rows.indices {
            guard rows[index].status == .pending,
                  let suggestion = rows[index].suggestion,
                  suggestion.confidence >= Self.highConfidenceThreshold,
                  let transaction = transactions[rows[index].id]
            else { continue }
            if apply(
                suggestion.target, toRowAt: index, transaction: transaction,
                in: context, categories: categories, businesses: businesses,
                save: false) {
                applied += 1
            }
        }
        if applied > 0 { try? context.save() }
        return applied
    }

    /// How many pending rows carry a suggestion at or above the
    /// accept-all threshold — drives the button's enabled state.
    var highConfidenceCount: Int {
        rows.filter {
            $0.status == .pending
                && ($0.suggestion?.confidence ?? 0) >= Self.highConfidenceThreshold
        }.count
    }

    /// Called after the transfer conversion flow converted the row's
    /// transaction — flips it to accepted.
    func markConverted(_ id: UUID) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].status = .accepted
        appliedCount += 1
    }

    /// One row's application. `save == false` batches the caller's writes
    /// into a single `context.save()`.
    private func apply(
        _ target: AICategorizationSuggestion.Target,
        toRowAt index: Int,
        transaction: LedgerTransaction,
        in context: ModelContext,
        categories: [UUID: LedgerCategory],
        businesses: [UUID: Business],
        save: Bool
    ) -> Bool {
        switch target {
        case .category(let categoryID):
            guard transaction.kind != .transfer,
                  let category = categories[categoryID],
                  category.kind == (transaction.kind == .income
                                    ? CategoryKind.income : .expense)
            else { return false }
            transaction.category = category
        case .business(let businessID):
            guard transaction.kind != .transfer,
                  let business = businesses[businessID]
            else { return false }
            transaction.business = business
        case .internalTransfer:
            // Flagged only — converting is the transfer picker's job.
            rows[index].status = .transferMarked
            return true
        }
        transaction.needsReview = false
        transaction.updatedAt = .now
        rows[index].status = .accepted
        appliedCount += 1
        if save { try? context.save() }
        return true
    }

    // MARK: - Merging

    /// Folds one batch's parsed suggestions into the row list: matched
    /// rows get their suggestion + resolved target name; untouched rows
    /// turn `.noSuggestion`.
    private func merge(
        _ parsed: [String: AICategorizationSuggestion],
        batch: [AIInboxSuggestRow],
        vocabulary: AIInboxVocabulary
    ) {
        for row in batch {
            guard let index = rows.firstIndex(where: { $0.id == row.id }),
                  rows[index].status == .pending else { continue }
            guard let suggestion = parsed[row.id.uuidString] else {
                rows[index].status = .noSuggestion
                continue
            }
            rows[index].suggestion = suggestion
            switch suggestion.target {
            case .category(let id), .business(let id):
                rows[index].targetName = vocabulary.name(for: id)
            case .internalTransfer:
                rows[index].targetName = "Chuyển khoản nội bộ"
            }
        }
    }
}
