import SwiftUI
import SwiftData
import FinanceCore

/// Pushed from a category row on the reports tab: every transaction of one
/// kind in one category — `categoryID == nil` is "Chưa phân loại" — inside
/// the displayed period and scope. Day-grouped; a row tap opens the
/// transaction in `TransactionEditorView`.
struct ReportsCategoryTransactionsView: View {
    let title: String
    let kind: TransactionKind
    let categoryID: UUID?
    let interval: ReportDateInterval
    let scope: ReportScope

    @Query private var transactions: [LedgerTransaction]
    @State private var editing: LedgerTransaction?

    init(
        title: String,
        kind: TransactionKind,
        categoryID: UUID?,
        interval: ReportDateInterval,
        scope: ReportScope
    ) {
        self.title = title
        self.kind = kind
        self.categoryID = categoryID
        self.interval = interval
        self.scope = scope
        // The predicate covers the period and the kind; the category and
        // scope filters apply in memory below (both are optional-id
        // comparisons, cheap on a personal-scale dataset).
        let start = interval.start
        let end = interval.end
        let kindRaw = kind.rawValue
        _transactions = Query(FetchDescriptor<LedgerTransaction>(
            predicate: #Predicate {
                $0.date >= start && $0.date < end && $0.kindRaw == kindRaw
            },
            sortBy: [SortDescriptor(\LedgerTransaction.date, order: .reverse)]
        ))
    }

    private func matches(_ transaction: LedgerTransaction) -> Bool {
        guard transaction.category?.id == categoryID else { return false }
        switch scope {
        case .all: return true
        case .personal: return transaction.business == nil
        case .anyBusiness: return transaction.business != nil
        case .business(let id): return transaction.business?.id == id
        }
    }

    private var byID: [UUID: LedgerTransaction] {
        Dictionary(transactions.map { ($0.id, $0) }) { first, _ in first }
    }

    private var sections: [TransactionListDaySection] {
        TransactionListGrouping.sections(
            for: transactions.filter(matches).map {
                TransactionListRow(transaction: $0)
            })
    }

    var body: some View {
        List {
            ForEach(sections) { section in
                Section {
                    ForEach(section.rows) { row in
                        Button {
                            editing = byID[row.id]
                        } label: {
                            TransactionListRowView(row: row)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    HStack {
                        Text(AppDateFormat.dayHeader(section.day, now: .now))
                        Spacer()
                        if section.incomeTotal > 0 {
                            AmountText(
                                amount: section.incomeTotal,
                                kind: .income, compact: true)
                        }
                        if section.expenseTotal > 0 {
                            AmountText(
                                amount: section.expenseTotal,
                                kind: .expense, compact: true)
                        }
                    }
                    .font(.caption)
                    .textCase(nil)
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if sections.isEmpty {
                EmptyStateView(
                    symbol: "tray",
                    title: "Không có giao dịch",
                    message: "Không có giao dịch nào trong kỳ này."
                )
            }
        }
        .sheet(item: $editing) { transaction in
            TransactionEditorView(transaction: transaction)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
    }
}
