import Foundation
import Observation
import SwiftData
import UIKit
import FinanceCore

/// One-shot completion seam over `AIClient` so the capture flow can be
/// driven by a fake in tests — the view and model never talk HTTP.
protocol AICaptureServicing: Sendable {
    func complete(_ request: AIRequest) async throws -> AIResponse
}

extension AIClient: AICaptureServicing {}

/// The accounts, categories and businesses the capture flow resolves
/// model-returned names into. Lookups skip archived rows — those stay
/// invisible to the pickers and to validation, exactly like the manual
/// transaction editor.
struct AICaptureCatalog {
    var categories: [LedgerCategory] = []
    var accounts: [Account] = []
    var businesses: [Business] = []

    var usableAccounts: [Account] { accounts.filter { !$0.isArchived } }
    var usableCategories: [LedgerCategory] { categories.filter { !$0.isArchived } }
    var usableBusinesses: [Business] { businesses.filter { !$0.isArchived } }

    func account(for id: UUID?) -> Account? {
        usableAccounts.first { $0.id == id }
    }

    func category(for id: UUID?) -> LedgerCategory? {
        usableCategories.first { $0.id == id }
    }

    func business(for id: UUID?) -> Business? {
        usableBusinesses.first { $0.id == id }
    }

    /// The names the extraction prompt lists for the model.
    func promptInput(now: Date) -> AITransactionExtraction.PromptInput {
        AITransactionExtraction.PromptInput(
            now: now,
            expenseCategories: usableCategories
                .filter { $0.kind == .expense }.map(\.name),
            incomeCategories: usableCategories
                .filter { $0.kind == .income }.map(\.name),
            accounts: usableAccounts.map { (name: $0.name, kind: $0.kind) },
            businesses: usableBusinesses.map(\.name)
        )
    }

    /// The name → id tables `AITransactionExtraction.parse` validates with.
    func matchTables() -> AITransactionExtraction.MatchTables {
        AITransactionExtraction.MatchTables(
            expenseCategories: AINameIndex(names: categoryNames(of: .expense)),
            incomeCategories: AINameIndex(names: categoryNames(of: .income)),
            accounts: AINameIndex(names: Dictionary(
                uniqueKeysWithValues: usableAccounts.map { ($0.id, $0.name) })),
            businesses: AINameIndex(names: Dictionary(
                uniqueKeysWithValues: usableBusinesses.map { ($0.id, $0.name) }))
        )
    }

    private func categoryNames(of kind: CategoryKind) -> [UUID: String] {
        Dictionary(uniqueKeysWithValues: usableCategories
            .filter { $0.kind == kind }.map { ($0.id, $0.name) })
    }
}

/// One extracted transaction the owner reviews before saving. Ids — not
/// model objects — are stored so the card survives catalog refreshes;
/// validity always goes through `TransactionDraft` so the exact rules of
/// the manual editor apply.
struct AICaptureItem: Identifiable {
    let id: UUID
    var kind: TransactionKind
    var amount: Int64
    var date: Date
    var note: String
    var categoryID: UUID?
    var accountID: UUID?
    var toAccountID: UUID?
    var businessID: UUID?
    /// Model self-reported certainty, clamped to 0...1.
    var confidence: Double
    /// Vietnamese hints produced during extraction (unmatched names,
    /// clamped dates…). Shown under the card — they flag, never block.
    var warnings: [String]

    /// Maps one validated extraction draft to an editable card.
    /// `fallbackAccountID` fills the source account when — and only when —
    /// the model returned none ("the last used account" rule).
    init(draft: AIDraftTransaction, fallbackAccountID: UUID? = nil) {
        id = UUID()
        kind = draft.kind
        amount = draft.amount
        date = draft.date
        note = draft.note
        categoryID = draft.categoryID
        accountID = draft.accountID ?? fallbackAccountID
        toAccountID = draft.toAccountID
        businessID = draft.businessID
        confidence = min(max(draft.confidence, 0), 1)
        warnings = draft.warnings
    }

    /// Switch kind, dropping fields that no longer apply — the id-level
    /// mirror of `TransactionDraft.setKind`: transfers carry neither
    /// category nor business, expense/income carry no destination, and a
    /// category of the wrong kind is cleared.
    mutating func setKind(_ newKind: TransactionKind, catalog: AICaptureCatalog) {
        guard newKind != kind else { return }
        kind = newKind
        if newKind == .transfer {
            categoryID = nil
            businessID = nil
        } else {
            toAccountID = nil
            if let categoryID,
               catalog.category(for: categoryID)?.kind
                    != TransactionDraft.categoryKind(for: newKind) {
                self.categoryID = nil
            }
        }
    }

    /// Resolves every stored id against the catalog into the canonical
    /// draft — the same value `TransactionEditorView` inserts.
    func makeDraft(in catalog: AICaptureCatalog) -> TransactionDraft {
        var draft = TransactionDraft(kind: kind)
        draft.amount = amount
        draft.date = date
        draft.note = note
        draft.account = catalog.account(for: accountID)
        if kind == .transfer {
            draft.toAccount = catalog.account(for: toAccountID)
        } else {
            draft.category = catalog.category(for: categoryID)
            draft.business = catalog.business(for: businessID)
        }
        return draft
    }

    /// The canonical validation errors — the card blocks saving while any
    /// of these is non-empty.
    func validationIssues(in catalog: AICaptureCatalog) -> [TransactionDraftError] {
        makeDraft(in: catalog).validate()
    }

    func isValid(in catalog: AICaptureCatalog) -> Bool {
        validationIssues(in: catalog).isEmpty
    }
}

/// The "AI nhập chi tiêu" flow behind `AICaptureView`:
/// `idle → analyzing → review → saved`, with `failed` keeping the inputs
/// for a retry. Owns the prompt + bill photos, calls the provider through
/// `AICaptureServicing`, turns the reply into editable `AICaptureItem`s
/// and persists them through `TransactionDraft` in one save.
///
/// Bill photos are sent with the request and then dropped — they are
/// never stored, neither on disk nor in SwiftData.
@MainActor
@Observable
final class AICaptureModel {
    /// Where the flow sits. `failed` carries the user-facing message so
    /// the input screen can show it above the untouched inputs.
    enum Phase: Equatable {
        case idle
        case analyzing
        case review
        case saved
        case failed(String)
    }

    /// At most this many photos ride on one request (`AIImagePreparer`'s cap).
    static let maxImages = AIImagePreparer.maxImages
    /// Auto-save fires only at or above this confidence on every item.
    static let autoSaveConfidence = 0.9
    /// An auto-saved batch can be undone within this many seconds.
    static let undoWindow: TimeInterval = 5

    // MARK: Inputs — kept through failures and cancellation

    var prompt = ""
    var images: [UIImage] = []
    /// Mirror of the "Tự lưu khi độ tin cậy cao" toggle; the view syncs it
    /// from its @AppStorage so the model stays testable without SwiftUI.
    var autoSaveEnabled = false
    /// The data the pickers and name matchers resolve against — refreshed
    /// by the view's @Query on appear and on every change.
    var catalog = AICaptureCatalog()

    // MARK: Outputs

    private(set) var phase: Phase = .idle
    /// Extracted items as editable cards — mutated by the review UI.
    var items: [AICaptureItem] = []
    /// Items the model emitted that failed validation (kept for display).
    private(set) var rejections: [AIExtractionRejection] = []
    /// The model's own message — a caveat, or why nothing was extracted.
    private(set) var modelMessage: String?
    /// Rows inserted by the last `saveAll` — shown on the saved screen.
    private(set) var savedTransactions: [LedgerTransaction] = []
    /// Whether the last save was the automatic high-confidence one.
    private(set) var savedAutomatically = false
    /// Undo stays available until this instant after an auto-save.
    private(set) var undoDeadline: Date?
    /// The in-flight analysis task — cancelled by `cancelAnalysis()`.
    private(set) var analysisTask: Task<Void, Never>?

    private let makeService: () throws -> any AICaptureServicing
    private let defaults: UserDefaults
    private let now: () -> Date

    init(
        makeService: @escaping () throws -> any AICaptureServicing,
        catalog: AICaptureCatalog = AICaptureCatalog(),
        defaults: UserDefaults = .standard,
        autoSaveEnabled: Bool = false,
        now: @escaping () -> Date = { .now }
    ) {
        self.makeService = makeService
        self.catalog = catalog
        self.defaults = defaults
        self.autoSaveEnabled = autoSaveEnabled
        self.now = now
    }

    // MARK: - Analysis

    /// A request can start: something to send and nothing in flight.
    var canAnalyze: Bool {
        phase != .analyzing
            && (!prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !images.isEmpty)
    }

    func addImage(_ image: UIImage) {
        guard images.count < Self.maxImages else { return }
        images.append(image)
    }

    /// Kicks off the provider request in the background. No-op while one
    /// is in flight or when there is nothing to send.
    func startAnalysis(context: ModelContext) {
        guard canAnalyze, analysisTask == nil else { return }
        analysisTask = Task { await performAnalysis(context: context) }
    }

    /// "Huỷ" during analysis — the request is aborted and the flow lands
    /// back on the input screen with prompt and photos untouched.
    func cancelAnalysis() {
        analysisTask?.cancel()
    }

    /// The actual request — also called directly by tests. Sends the
    /// prompt and the prepared photos, parses the reply into items and
    /// either auto-saves (when enabled and every item is confident and
    /// valid) or lands on the review screen.
    func performAnalysis(context: ModelContext) async {
        defer { analysisTask = nil }

        let service: any AICaptureServicing
        do {
            service = try makeService()
        } catch {
            phase = .failed(message(for: error))
            return
        }

        phase = .analyzing
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let prepared = AIImagePreparer.prepareImages(images)
        let userText = trimmed.isEmpty
            ? "Hãy đọc hoá đơn trong ảnh và trích xuất các giao dịch."
            : trimmed
        let system = AITransactionExtraction.systemPrompt(
            for: catalog.promptInput(now: now()))
        let request = AIRequest.text(
            userText, system: system, images: prepared, jsonMode: true)

        do {
            let response = try await service.complete(request)
            // The request has been answered — bill photos are dropped
            // here; nothing stores them.
            images = []
            let result = AITransactionExtraction.parse(
                response.text, tables: catalog.matchTables(), now: now())
            apply(result: result)
            guard !result.drafts.isEmpty else {
                phase = .review
                return
            }
            if autoSaveEnabled && eligibleForAutoSave {
                do {
                    try saveAll(context: context, automatically: true)
                } catch {
                    // A failed commit never loses the extraction — the
                    // owner can save manually from the review screen.
                    phase = .review
                }
            } else {
                phase = .review
            }
        } catch is CancellationError {
            phase = .idle
        } catch {
            phase = .failed(message(for: error))
        }
    }

    private func apply(result: AIExtractionResult) {
        rejections = result.rejections
        modelMessage = result.message
        if result.drafts.isEmpty && modelMessage == nil {
            modelMessage = "Không đọc được giao dịch nào từ nội dung đã gửi."
        }
        let fallback = fallbackAccountID()
        items = result.drafts.map {
            AICaptureItem(draft: $0, fallbackAccountID: fallback)
        }
        savedTransactions = []
        savedAutomatically = false
        undoDeadline = nil
    }

    /// The quick-add editor's last-used account — the same AppStorage key
    /// `TransactionEditorView` writes. Honoured only while it still
    /// points at a usable account.
    private func fallbackAccountID() -> UUID? {
        guard let raw = defaults.string(
            forKey: DataResetService.lastUsedAccountDefaultsKey),
            let id = UUID(uuidString: raw),
            catalog.account(for: id) != nil else { return nil }
        return id
    }

    // MARK: - Review

    /// "Lưu tất cả" is enabled only when every remaining item can really
    /// be saved — invalid items must be fixed or removed first.
    var canSaveAll: Bool {
        !items.isEmpty && items.allSatisfy { $0.isValid(in: catalog) }
    }

    /// The auto-save rule: at least one item, every item saveable and
    /// every item at or above `autoSaveConfidence`.
    var eligibleForAutoSave: Bool {
        !items.isEmpty && items.allSatisfy {
            $0.confidence >= Self.autoSaveConfidence && $0.isValid(in: catalog)
        }
    }

    func removeItem(_ item: AICaptureItem) {
        items.removeAll { $0.id == item.id }
    }

    /// Back from the "nothing extracted" result to the input screen —
    /// the prompt stays so the owner can rephrase and try again.
    func backToInput() {
        guard phase == .review else { return }
        phase = .idle
    }

    // MARK: - Saving

    /// Inserts every *valid* item through `TransactionDraft` (all normal
    /// rules apply) and commits once. Invalid items are skipped — the
    /// review screen already forces them fixed or removed via
    /// `canSaveAll`. Returns the number of inserted rows.
    @discardableResult
    func saveAll(context: ModelContext, automatically: Bool = false) throws -> Int {
        var inserted: [LedgerTransaction] = []
        for item in items where item.isValid(in: catalog) {
            inserted.append(try item.makeDraft(in: catalog).insert(into: context))
        }
        guard !inserted.isEmpty else { return 0 }
        try context.save()

        savedTransactions = inserted
        savedAutomatically = automatically
        undoDeadline = automatically ? now().addingTimeInterval(Self.undoWindow) : nil
        if let lastAccountID = inserted.lazy.compactMap(\.account?.id).last {
            defaults.set(lastAccountID.uuidString,
                         forKey: DataResetService.lastUsedAccountDefaultsKey)
        }
        phase = .saved
        return inserted.count
    }

    /// Deletes the auto-saved batch while the undo window is open and
    /// returns to the review so nothing the model extracted is lost.
    func undoSaved(context: ModelContext) {
        guard savedAutomatically,
              let deadline = undoDeadline,
              now() < deadline else { return }
        for transaction in savedTransactions {
            LedgerTransactionDeletion.delete(transaction, in: context)
        }
        try? context.save()
        savedTransactions = []
        savedAutomatically = false
        undoDeadline = nil
        phase = .review
    }

    // MARK: - Errors

    private func message(for error: Error) -> String {
        if let aiError = error as? AIError,
           let description = aiError.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}
