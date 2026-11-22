import SwiftUI
import SwiftData
import FinanceCore

/// Sheet để AI gợi ý phân loại các giao dịch `needsReview` — presented from
/// the inbox, owns its NavigationStack. Queries the pending rows itself so
/// no inbox code had to change. The model runs in batches of 40; every
/// accepted suggestion writes category/business and clears `needsReview`
/// in a single save. "Chuyển khoản nội bộ" suggestions only flag the row
/// — the real conversion stays in `WalletSyncTransferPicker`.
@MainActor
struct AIInboxSuggestView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    /// Pending rows, newest first — the same predicate the inbox uses.
    @Query private var pending: [LedgerTransaction]
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query(sort: \LedgerCategory.sortOrder) private var categories: [LedgerCategory]
    @Query(sort: \Business.sortOrder) private var businesses: [Business]

    @State private var model: AIInboxSuggestModel
    /// Row whose target the user is changing by hand.
    @State private var changeTarget: AIInboxSuggestRow?
    /// Row flagged internal transfer, waiting for a destination pick.
    @State private var transferTarget: AIInboxSuggestRow?
    @State private var didAutoRun = false
    @State private var showsSettings = false

    init(
        client: (any AIChatClientProtocol)? = nil,
        store: AIProviderStore = AIProviderStore()
    ) {
        _pending = Query(
            filter: #Predicate { $0.needsReview == true },
            sort: \.date, order: .reverse)
        _model = State(initialValue: AIInboxSuggestModel(
            client: client, store: store))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Gợi ý phân loại")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
                .task { runIfNeeded() }
                .sheet(item: $changeTarget) { row in
                    AIInboxTargetPicker(row: row) { target in
                        applyChange(target, to: row)
                    }
                }
                .sheet(item: $transferTarget) { row in
                    transferPicker(for: row)
                }
                .navigationDestination(isPresented: $showsSettings) {
                    AISettingsView()
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !model.isConfigured {
            EmptyStateView(
                symbol: "cpu.fill",
                title: "Chưa cấu hình AI",
                message: "Thêm nhà cung cấp AI để nhận gợi ý phân loại giao dịch.",
                actionTitle: "Mở cài đặt AI"
            ) {
                showsSettings = true
            }
        } else if pending.isEmpty && model.rows.isEmpty {
            EmptyStateView(
                symbol: "checkmark.tray.fill",
                title: "Không còn gì chờ",
                message: "Mọi giao dịch nhập từ ngân hàng đã được phân loại.")
        } else {
            suggestionList
        }
    }

    // MARK: - Data plumbing

    private var pendingInputs: [AIInboxPendingInput] {
        pending.map {
            AIInboxPendingInput(
                transactionID: $0.id,
                kind: $0.kind,
                signedAmount: $0.kind == .income ? $0.amount : -$0.amount,
                note: $0.note,
                date: $0.date,
                accountName: $0.account?.name)
        }
    }

    private var vocabulary: AIInboxVocabulary {
        let live = categories.filter { !$0.isArchived }
        return AIInboxVocabulary(
            expenseCategories: live.filter { $0.kind == .expense }
                .map { (id: $0.id, name: $0.name) },
            incomeCategories: live.filter { $0.kind == .income }
                .map { (id: $0.id, name: $0.name) },
            businesses: businesses.filter { !$0.isArchived }
                .map { (id: $0.id, name: $0.name) })
    }

    private var transactionByID: [UUID: LedgerTransaction] {
        Dictionary(pending.map { ($0.id, $0) }) { first, _ in first }
    }

    private var categoryByID: [UUID: LedgerCategory] {
        Dictionary(categories.map { ($0.id, $0) }) { first, _ in first }
    }

    private var businessByID: [UUID: Business] {
        Dictionary(businesses.map { ($0.id, $0) }) { first, _ in first }
    }

    private func runIfNeeded() {
        guard model.isConfigured, !didAutoRun else { return }
        didAutoRun = true
        model.run(pending: pendingInputs, vocabulary: vocabulary)
    }

    /// The model run mutates no data — only explicit accepts do — so
    /// cancelling here (or dismissing) is persistence-safe.
    private func cancelAndDismiss() {
        model.cancel()
        dismiss()
    }

    // MARK: - List

    private var suggestionList: some View {
        List {
            statusSection
            Section {
                ForEach(model.rows) { row in
                    rowView(row)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var statusSection: some View {
        Section {
            switch model.phase {
            case .idle:
                Label("Sẵn sàng gợi ý lại khi cần.", systemImage: "sparkles")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            case .running(let done, let total):
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Đang gợi ý — lô \(done)/\(total)…")
                        .font(.subheadline)
                }
            case .finished:
                Label(
                    "Đã gợi ý xong · áp dụng \(model.appliedCount) giao dịch",
                    systemImage: "checkmark.circle.fill"
                )
                .font(.subheadline)
                .foregroundStyle(.green)
            case .failed(let message):
                VStack(alignment: .leading, spacing: 6) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                    HStack(spacing: 16) {
                        Button("Thử lại") {
                            model.run(
                                pending: pendingInputs, vocabulary: vocabulary)
                        }
                        Button("Bỏ qua lỗi") { model.clearError() }
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline.weight(.medium))
                }
            }
            if model.highConfidenceCount > 0 {
                Button {
                    _ = model.acceptAllHighConfidence(
                        in: context,
                        transactions: transactionByID,
                        categories: categoryByID,
                        businesses: businessByID)
                } label: {
                    Label(
                        "Chấp nhận tất cả gợi ý tin cậy cao (\(model.highConfidenceCount))",
                        systemImage: "checkmark.circle.badge.checkmark.fill"
                    )
                    .font(.subheadline.weight(.semibold))
                }
                .disabled(isRunning)
            }
            Button {
                model.run(pending: pendingInputs, vocabulary: vocabulary)
            } label: {
                Label("Gợi ý lại từ đầu", systemImage: "arrow.triangle.2.circlepath")
                    .font(.subheadline)
            }
            .disabled(isRunning || pending.isEmpty)
        }
    }

    private var isRunning: Bool {
        if case .running = model.phase { return true }
        return false
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            if isRunning {
                Button("Dừng") { model.cancel() }
            } else {
                Button("Đóng") { cancelAndDismiss() }
            }
        }
    }

    // MARK: - Rows

    private func rowView(_ row: AIInboxSuggestRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.input.note.isEmpty ? "Không có ghi chú" : row.input.note)
                        .font(.body)
                        .lineLimit(2)
                    Text([
                        AppDateFormat.shortDate(row.input.date),
                        AppDateFormat.time(row.input.date),
                        row.input.accountName,
                    ].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                AmountText(amount: row.amount, kind: row.input.kind)
                    .font(.subheadline.weight(.semibold))
            }
            actionArea(row)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { primaryAction(row) }
    }

    /// The obvious next step per row — accept the suggestion, or open the
    /// transfer picker for a flagged internal transfer.
    private func primaryAction(_ row: AIInboxSuggestRow) {
        switch row.status {
        case .pending:
            switch row.suggestion?.target {
            case .internalTransfer:
                transferTarget = row
            case .category, .business:
                _ = model.accept(
                    row.id, in: context,
                    transactions: transactionByID,
                    categories: categoryByID,
                    businesses: businessByID)
            case nil:
                break
            }
        case .transferMarked:
            transferTarget = row
        case .accepted, .noSuggestion:
            break
        }
    }

    @ViewBuilder
    private func actionArea(_ row: AIInboxSuggestRow) -> some View {
        switch row.status {
        case .pending:
            if let suggestion = row.suggestion {
                suggestionLine(row, suggestion: suggestion)
            } else {
                Label("Đang chờ gợi ý…", systemImage: "ellipsis")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .noSuggestion:
            HStack(spacing: 8) {
                Label("Chưa có gợi ý", systemImage: "questionmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                changeButton(row)
            }
        case .accepted:
            Label(
                "Đã áp dụng\(row.targetName.map { ": \($0)" } ?? "")",
                systemImage: "checkmark.circle.fill"
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(.green)
        case .transferMarked:
            HStack(spacing: 8) {
                targetChip(name: "Chuyển khoản nội bộ", transfer: true)
                Spacer()
                Button {
                    transferTarget = row
                } label: {
                    Text("Chọn tài khoản đích")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .foregroundStyle(Color.accentColor)
                        .background(
                            Color.accentColor.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func suggestionLine(
        _ row: AIInboxSuggestRow,
        suggestion: AICategorizationSuggestion
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                targetChip(
                    name: row.targetName ?? "Chưa rõ",
                    transfer: suggestion.target == .internalTransfer)
                Text("Độ tin cậy \(Int((suggestion.confidence * 100).rounded()))%")
                    .font(.caption2)
                    .foregroundStyle(
                        suggestion.confidence
                            >= AIInboxSuggestModel.highConfidenceThreshold
                            ? .green : .secondary)
            }
            HStack(spacing: 8) {
                switch suggestion.target {
                case .internalTransfer:
                    Button {
                        _ = model.accept(
                            row.id, in: context,
                            transactions: transactionByID,
                            categories: categoryByID,
                            businesses: businessByID)
                    } label: {
                        Text("Đánh dấu chuyển khoản")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .foregroundStyle(Color.accentColor)
                            .background(
                                Color.accentColor.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                case .category, .business:
                    Button {
                        _ = model.accept(
                            row.id, in: context,
                            transactions: transactionByID,
                            categories: categoryByID,
                            businesses: businessByID)
                    } label: {
                        Label("Chấp nhận", systemImage: "checkmark")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .foregroundStyle(.white)
                            .background(Color.accentColor, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                changeButton(row)
            }
        }
    }

    private func changeButton(_ row: AIInboxSuggestRow) -> some View {
        Button {
            changeTarget = row
        } label: {
            Text("Đổi")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .foregroundStyle(.secondary)
                .background(
                    Color(.tertiarySystemFill), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func targetChip(name: String, transfer: Bool) -> some View {
        Label(
            name,
            systemImage: transfer ? "arrow.left.arrow.right" : "tag.fill"
        )
        .font(.caption.weight(.medium))
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .foregroundStyle(transfer ? .white : Color.accentColor)
        .background(
            transfer ? Color.accentColor : Color.accentColor.opacity(0.12),
            in: Capsule())
    }

    // MARK: - Actions

    private func applyChange(
        _ target: AICategorizationSuggestion.Target,
        to row: AIInboxSuggestRow
    ) {
        if target == .internalTransfer {
            // Flag it, then immediately ask for the destination account.
            _ = model.change(
                row.id, to: target, in: context,
                transactions: transactionByID,
                categories: categoryByID,
                businesses: businessByID)
            transferTarget = row
            return
        }
        _ = model.change(
            row.id, to: target, in: context,
            transactions: transactionByID,
            categories: categoryByID,
            businesses: businessByID)
    }

    private func transferPicker(for row: AIInboxSuggestRow) -> some View {
        let transaction = transactionByID[row.id]
        return WalletSyncTransferPicker(
            accounts: accounts.filter {
                !$0.isArchived && $0.id != transaction?.account?.id
            }
        ) { picked in
            // `onPick` is nonisolated — hop for the model/context writes.
            Task { @MainActor in
                guard let transaction else { return }
                // The existing conversion flow — this is where an internal
                // transfer actually becomes one. Never called automatically.
                if WalletSyncTransfer.convert(transaction, with: picked) {
                    try? context.save()
                    model.markConverted(row.id)
                }
            }
        }
    }
}

/// The "Đổi" picker: valid categories for the row's direction, every
/// business, and the internal-transfer choice. Owns its NavigationStack —
/// it is itself a sheet.
@MainActor
private struct AIInboxTargetPicker: View {
    let row: AIInboxSuggestRow
    let onPick: @MainActor (AICategorizationSuggestion.Target) -> Void

    @Environment(\.dismiss) private var dismiss
    @Query(sort: \LedgerCategory.sortOrder) private var categories: [LedgerCategory]
    @Query(sort: \Business.sortOrder) private var businesses: [Business]

    var body: some View {
        NavigationStack {
            List {
                Section("Danh mục") {
                    ForEach(categoriesForRow) { category in
                        targetRow(
                            name: category.name,
                            symbol: category.icon,
                            colorHex: category.colorHex
                        ) {
                            pick(.category(category.id))
                        }
                    }
                }
                if !liveBusinesses.isEmpty {
                    Section("Mảng kinh doanh") {
                        ForEach(liveBusinesses) { business in
                            targetRow(
                                name: business.name,
                                symbol: business.icon,
                                colorHex: business.colorHex
                            ) {
                                pick(.business(business.id))
                            }
                        }
                    }
                }
                Section {
                    targetRow(
                        name: "Chuyển khoản nội bộ",
                        symbol: "arrow.left.arrow.right",
                        colorHex: "0A84FF"
                    ) {
                        pick(.internalTransfer)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Đổi phân loại")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Huỷ") { dismiss() }
                }
            }
        }
    }

    /// Expense rows offer expense categories, income rows income
    /// categories; a transfer row (rare here) offers both.
    private var categoriesForRow: [LedgerCategory] {
        let live = categories.filter { !$0.isArchived }
        switch row.input.kind {
        case .income: return live.filter { $0.kind == .income }
        case .expense: return live.filter { $0.kind == .expense }
        case .transfer: return live
        }
    }

    private var liveBusinesses: [Business] {
        businesses.filter { !$0.isArchived }
    }

    private func pick(_ target: AICategorizationSuggestion.Target) {
        onPick(target)
        dismiss()
    }

    private func targetRow(
        name: String, symbol: String, colorHex: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            IconBadge(
                symbol: symbol.isEmpty ? AppTheme.fallbackSymbol : symbol,
                colorHex: colorHex, size: 30)
            Text(name)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
}

/// Preview-only client: echoes a "Ăn uống" suggestion for every row so the
/// sheet renders its full state without a provider.
private struct AIInboxPreviewClient: AIChatClientProtocol {
    func complete(_ request: AIRequest) async throws -> AIResponse {
        guard let text = request.messages.first?.text,
              let data = text.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data)
                  as? [[String: Any]]
        else { return AIResponse(text: #"{"suggestions":[]}"#) }
        let suggestions: [[String: Any]] = rows.enumerated().map { index, row in
            var item: [String: Any] = [
                "id": row["id"] ?? "",
                "transfer": index % 3 == 0,
                "confidence": index % 2 == 0 ? 0.9 : 0.6,
            ]
            item["category"] = index % 3 == 0 ? NSNull() : "Ăn uống"
            item["business"] = NSNull()
            return item
        }
        let body = try? JSONSerialization.data(
            withJSONObject: ["suggestions": suggestions])
        return AIResponse(
            text: body.flatMap { String(data: $0, encoding: .utf8) } ?? "{}")
    }

    func stream(_ request: AIRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

#Preview {
    let container = try! AppModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    try! SeedData.seedIfNeeded(context: context)
    let cash = try! context.fetch(FetchDescriptor<Account>()).first!
    for (index, note) in [
        "GRAB BIKE SGN", "LUONG THANG 11", "HIGHLANDS COFFEE",
        "CK TIET KIEM", "LOTTE MART", "SPOTIFY PREMIUM",
    ].enumerated() {
        context.insert(LedgerTransaction(
            kind: index == 1 ? .income : .expense,
            amount: 80_000 + Int64(index) * 45_000,
            date: .now.addingTimeInterval(Double(-index) * 43_200),
            note: note, account: cash, needsReview: true))
    }
    return AIInboxSuggestView(client: AIInboxPreviewClient())
        .modelContainer(container)
}
