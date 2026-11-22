import Foundation
import FinanceCore

/// Direction filter of a `WalletSyncRule` — restrict the match to money
/// in, money out, or either.
enum WalletSyncRuleDirection: String, Codable, CaseIterable, Sendable {
    case any
    case moneyIn
    case moneyOut

    var displayName: String {
        switch self {
        case .any: return "Tất cả"
        case .moneyIn: return "Tiền vào"
        case .moneyOut: return "Tiền ra"
        }
    }
}

/// What a matching rule does to the transaction.
enum WalletSyncRuleAction: Codable, Equatable, Sendable {
    /// Fill `category` (kind must still fit the transaction kind).
    case category(UUID)
    /// Fill `business`.
    case business(UUID)
    /// Convert into an internal transfer with this account as counterpart.
    case transfer(UUID)
}

/// One auto-categorization rule: if the bank note contains `keyword`
/// (case- and diacritic-insensitive) and the direction matches, `action`
/// applies. Stored as a JSON array in UserDefaults; the array order is the
/// priority — the first matching rule with a live target wins.
struct WalletSyncRule: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var keyword: String
    var direction: WalletSyncRuleDirection
    var action: WalletSyncRuleAction

    init(
        id: UUID = UUID(),
        keyword: String,
        direction: WalletSyncRuleDirection = .any,
        action: WalletSyncRuleAction
    ) {
        self.id = id
        self.keyword = keyword
        self.direction = direction
        self.action = action
    }

    /// Substring match on the note after the same folding the app uses for
    /// names: case and diacritics are ignored ("ĂN UỐNG" matches "an uong")
    /// and Vietnamese "đ" folds to "d".
    func matches(note: String, moneyIn: Bool) -> Bool {
        switch direction {
        case .any:
            break
        case .moneyIn:
            guard moneyIn else { return false }
        case .moneyOut:
            guard !moneyIn else { return false }
        }
        let foldedKeyword = SettingsNameNormalizer.fold(keyword)
        guard !foldedKeyword.isEmpty else { return false }
        return SettingsNameNormalizer.fold(note).contains(foldedKeyword)
    }
}

/// Storage seam for rules — UserDefaults in the app, in-memory in tests.
protocol WalletSyncRuleStoring: Sendable {
    /// Rules in priority order: index 0 applies first.
    func loadRules() -> [WalletSyncRule]
    func saveRules(_ rules: [WalletSyncRule])
}

/// UserDefaults-backed rule store — one JSON array kept in priority order.
final class WalletSyncRuleStore: WalletSyncRuleStoring, @unchecked Sendable {
    static let key = "walletSync.rules"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadRules() -> [WalletSyncRule] {
        guard let data = defaults.data(forKey: Self.key),
              let rules = try? JSONDecoder().decode([WalletSyncRule].self, from: data)
        else { return [] }
        return rules
    }

    func saveRules(_ rules: [WalletSyncRule]) {
        defaults.set(try? JSONEncoder().encode(rules), forKey: Self.key)
    }
}

/// Volatile `WalletSyncRuleStoring` for tests and previews.
final class WalletSyncInMemoryRuleStore: WalletSyncRuleStoring, @unchecked Sendable {
    private(set) var rules: [WalletSyncRule]

    init(rules: [WalletSyncRule] = []) {
        self.rules = rules
    }

    func loadRules() -> [WalletSyncRule] { rules }

    func saveRules(_ rules: [WalletSyncRule]) { self.rules = rules }
}

/// Converts an imported income/expense row into an internal transfer with
/// `other` as the counterpart account. Direction-aware: an expense keeps
/// the imported account as source (money left it); an income makes `other`
/// the source (money arrived from it).
enum WalletSyncTransfer {
    /// Performs the conversion in place. Returns false when the row is
    /// already a transfer, has no source account, or `other` is its source.
    @discardableResult
    static func convert(_ transaction: LedgerTransaction, with other: Account) -> Bool {
        guard transaction.kind != .transfer,
              let source = transaction.account,
              source.id != other.id
        else { return false }
        if transaction.kind == .income {
            transaction.toAccount = source
            transaction.account = other
        } else {
            transaction.toAccount = other
        }
        transaction.kind = .transfer
        transaction.category = nil
        transaction.business = nil
        transaction.needsReview = false
        transaction.updatedAt = .now
        return true
    }
}

/// Applies rules to one transaction. The first rule in order whose keyword
/// and direction match AND whose target still exists wins; dead-target
/// rules are skipped so a later live rule can still apply.
enum WalletSyncRuleApplier {
    /// The applied rule, or nil when nothing matched. `needsReview` is
    /// cleared on success.
    @discardableResult
    static func apply(
        to transaction: LedgerTransaction,
        rules: [WalletSyncRule],
        categories: [UUID: LedgerCategory],
        businesses: [UUID: Business],
        accounts: [UUID: Account]
    ) -> WalletSyncRule? {
        let moneyIn = transaction.kind == .income
        for rule in rules where rule.matches(note: transaction.note, moneyIn: moneyIn) {
            guard applyAction(
                rule, to: transaction,
                categories: categories, businesses: businesses,
                accounts: accounts)
            else { continue }
            return rule
        }
        return nil
    }

    /// Executes a matched rule's action on the transaction — shared by the
    /// plain applier and `WalletSyncCompiledRules`. False means the rule's
    /// target was dead or the action did not apply, so the next rule runs.
    @discardableResult
    static func applyAction(
        _ rule: WalletSyncRule,
        to transaction: LedgerTransaction,
        categories: [UUID: LedgerCategory],
        businesses: [UUID: Business],
        accounts: [UUID: Account]
    ) -> Bool {
        let moneyIn = transaction.kind == .income
        switch rule.action {
        case .category(let id):
            guard transaction.kind != .transfer,
                  let category = categories[id],
                  category.kind == (moneyIn ? CategoryKind.income : .expense)
            else { return false }
            transaction.category = category
        case .business(let id):
            guard transaction.kind != .transfer,
                  let business = businesses[id]
            else { return false }
            transaction.business = business
        case .transfer(let accountID):
            guard transaction.kind != .transfer,
                  let other = accounts[accountID],
                  WalletSyncTransfer.convert(transaction, with: other)
            else { return false }
            return true
        }
        transaction.needsReview = false
        transaction.updatedAt = .now
        return true
    }
}

/// Rules with pre-folded keywords — built once per sync so a large import
/// folds each note once instead of once per rule per row.
struct WalletSyncCompiledRules: Sendable {
    let rules: [WalletSyncRule]
    private let foldedKeywords: [String]

    init(rules: [WalletSyncRule]) {
        self.rules = rules
        foldedKeywords = rules.map { SettingsNameNormalizer.fold($0.keyword) }
    }

    /// Same first-live-match semantics as `WalletSyncRuleApplier.apply`.
    @discardableResult
    func apply(
        to transaction: LedgerTransaction,
        categories: [UUID: LedgerCategory],
        businesses: [UUID: Business],
        accounts: [UUID: Account]
    ) -> WalletSyncRule? {
        let moneyIn = transaction.kind == .income
        let foldedNote = SettingsNameNormalizer.fold(transaction.note)
        for index in rules.indices {
            let rule = rules[index]
            switch rule.direction {
            case .any:
                break
            case .moneyIn:
                guard moneyIn else { continue }
            case .moneyOut:
                guard !moneyIn else { continue }
            }
            let keyword = foldedKeywords[index]
            guard !keyword.isEmpty, foldedNote.contains(keyword)
            else { continue }
            guard WalletSyncRuleApplier.applyAction(
                rule, to: transaction,
                categories: categories, businesses: businesses,
                accounts: accounts)
            else { continue }
            return rule
        }
        return nil
    }
}
