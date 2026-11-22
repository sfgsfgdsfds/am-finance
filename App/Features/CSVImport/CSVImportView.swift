import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Three-step CSV statement import — pick file + account, map columns
/// with a live preview, confirm the summary. Pushed inside an existing
/// NavigationStack (Settings → Nhập sao kê CSV); it must not wrap itself
/// in one.
struct CSVImportView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Account.sortOrder) private var accounts: [Account]

    private let ruleStore: any WalletSyncRuleStoring
    private let stateStore: any WalletSyncStateStoring
    private let batchStore: any CSVImportBatchStoring
    private let mappingStore: any CSVImportMappingStoring

    enum Step {
        case source, mapping, confirm
    }

    @State private var step = Step.source
    @State private var accountID: UUID?
    @State private var document: CSVImportDocument?
    @State private var mapping = CSVImportMapping()
    /// Separate UI state for the "one column / out-in pair" switch so the
    /// choice sticks even before any amount column is mapped.
    @State private var usePairColumns = false
    @State private var mapped = CSVImportMappedRows(drafts: [], errors: [])
    /// Step-3 snapshot: drafts after id assignment + dedupe.
    @State private var importable: [CSVImportDraft] = []
    @State private var skippedDuplicates = 0
    @State private var lastBatch: CSVImportBatch?

    @State private var showsFileImporter = false
    @State private var showsUndoConfirm = false
    @State private var notice: CSVImportNotice?

    init(
        ruleStore: (any WalletSyncRuleStoring)? = nil,
        stateStore: (any WalletSyncStateStoring)? = nil,
        batchStore: (any CSVImportBatchStoring)? = nil,
        mappingStore: (any CSVImportMappingStoring)? = nil
    ) {
        self.ruleStore = ruleStore ?? WalletSyncRuleStore()
        self.stateStore = stateStore ?? WalletSyncStateStore()
        self.batchStore = batchStore ?? CSVImportBatchStore()
        self.mappingStore = mappingStore ?? CSVImportMappingStore()
    }

    private var importer: CSVImportImporter {
        CSVImportImporter(
            context: context,
            ruleStore: ruleStore,
            stateStore: stateStore,
            batchStore: batchStore)
    }

    private var targets: [Account] {
        accounts.filter { !$0.isArchived }
    }

    private var selectedAccount: Account? {
        targets.first { $0.id == accountID } ?? targets.first
    }

    var body: some View {
        Form {
            switch step {
            case .source: sourceSections
            case .mapping: mappingSections
            case .confirm: confirmSections
            }
        }
        .navigationTitle(title)
        .toolbar {
            if step != .source {
                ToolbarItem(placement: .navigation) {
                    Button("Quay lại") {
                        withAnimation { step = step == .confirm ? .mapping : .source }
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $showsFileImporter,
            allowedContentTypes: [
                .commaSeparatedText, .tabSeparatedText,
                .plainText, .utf8PlainText,
            ]
        ) { result in
            handleFile(result)
        }
        .confirmationDialog(
            "Hoàn tác lần nhập gần nhất?",
            isPresented: $showsUndoConfirm,
            titleVisibility: .visible
        ) {
            Button("Xoá \(lastBatch?.ids.count ?? 0) giao dịch đã nhập",
                   role: .destructive) {
                performUndo()
            }
            Button("Huỷ", role: .cancel) {}
        } message: {
            Text("Giao dịch đã xoá sẽ không được nhập lại từ cùng một tệp.")
        }
        .alert("Nhập sao kê CSV", isPresented: noticePresented,
               presenting: notice) { _ in
            Button("OK") {}
        } message: { notice in
            Text(notice.message)
        }
        .onAppear {
            if accountID == nil { accountID = targets.first?.id }
            refreshBatch()
        }
        .onChange(of: accountID) { _, _ in refreshBatch() }
        .onChange(of: mapping) { _, _ in recompute() }
    }

    private var title: String {
        switch step {
        case .source: return "Nhập sao kê CSV"
        case .mapping: return "Ghép cột"
        case .confirm: return "Xác nhận nhập"
        }
    }

    // MARK: - Step 1: file + account

    @ViewBuilder
    private var sourceSections: some View {
        Section {
            Button {
                showsFileImporter = true
            } label: {
                Label("Chọn tệp CSV…", systemImage: "doc.badge.arrow.down")
            }
        } header: {
            Text("Tệp sao kê")
        } footer: {
            Text("Chọn tệp sao kê ngân hàng/thẻ dạng CSV hoặc văn bản. Tệp Excel (.xlsx) cần được lưu lại dưới dạng CSV trước khi nhập.")
        }

        Section {
            Picker("Tài khoản nhận", selection: $accountID) {
                ForEach(targets, id: \.id) { account in
                    Text(account.name).tag(Optional(account.id))
                }
            }
        } header: {
            Text("Tài khoản")
        } footer: {
            Text("Giao dịch trong tệp sẽ được nhập vào tài khoản này. Tài khoản đã lưu trữ không hiển thị.")
        }

        if let batch = lastBatch, !batch.ids.isEmpty, let account = selectedAccount {
            Section {
                Button(role: .destructive) {
                    showsUndoConfirm = true
                } label: {
                    Label("Hoàn tác lần nhập gần nhất",
                          systemImage: "arrow.uturn.backward")
                }
            } footer: {
                Text("Xoá \(batch.ids.count) giao dịch đã nhập vào \"\(account.name)\" lúc \(AppDateFormat.shortDate(batch.importedAt)) \(AppDateFormat.time(batch.importedAt)).")
            }
        }
    }

    // MARK: - Step 2: mapping + preview

    @ViewBuilder
    private var mappingSections: some View {
        if let document {
            Section {
                LabeledContent("Tệp", value: document.fileName)
                LabeledContent("Dấu phân tách", value: document.delimiter.displayName)
                LabeledContent(
                    "Dữ liệu",
                    value: "\(document.headers.count) cột · \(document.rows.count) dòng")
            } header: {
                Text("Tệp")
            }
        }

        Section {
            Picker("Kiểu số tiền", selection: $usePairColumns) {
                Text("Một cột có dấu").tag(false)
                Text("Hai cột ghi nợ / ghi có").tag(true)
            }
            .pickerStyle(.segmented)
            .onChange(of: usePairColumns) { _, pair in
                if pair {
                    mapping.amountColumn = nil
                } else {
                    mapping.moneyOutColumn = nil
                    mapping.moneyInColumn = nil
                }
            }
        }

        Section {
            columnPicker("Ngày", keyPath: \.dateColumn)
            if usePairColumns {
                columnPicker("Tiền ra (ghi nợ)", keyPath: \.moneyOutColumn)
                columnPicker("Tiền vào (ghi có)", keyPath: \.moneyInColumn)
            } else {
                columnPicker("Số tiền", keyPath: \.amountColumn)
            }
            columnPicker("Mô tả", keyPath: \.descriptionColumn)
            columnPicker("Số tham chiếu (tuỳ chọn)", keyPath: \.referenceColumn)
        } header: {
            Text("Cột")
        } footer: {
            Text("Chọn cột tương ứng trong tệp. Ghi nợ là tiền ra khỏi tài khoản, ghi có là tiền vào.")
        }

        Section {
            Picker("Định dạng ngày", selection: $mapping.dateFormat) {
                ForEach(CSVImportDateFormat.allCases, id: \.self) { format in
                    Text(format.displayName).tag(format)
                }
            }
            Picker("Định dạng số", selection: $mapping.numberFormat) {
                ForEach(CSVImportNumberFormatStyle.allCases, id: \.self) { style in
                    Text(style.displayName).tag(style)
                }
            }
            Toggle("Đảo dấu (chi là số dương)", isOn: $mapping.flipSign)
        } header: {
            Text("Định dạng")
        } footer: {
            Text("Bật \"Đảo dấu\" cho sao kê thẻ tín dụng ghi số tiền chi là số dương.")
        }

        Section {
            if mapped.drafts.isEmpty, mapped.errors.isEmpty {
                Text("Chưa chọn đủ cột để xem trước.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(mapped.drafts.prefix(20), id: \.rowNumber) { draft in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(draft.note.isEmpty ? "Không có mô tả" : draft.note)
                                .font(.subheadline)
                                .lineLimit(1)
                            Text("\(AppDateFormat.shortDate(draft.date)) \(AppDateFormat.time(draft.date))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        AmountText(
                            amount: draft.signedAmount,
                            kind: draft.signedAmount >= 0 ? .income : .expense)
                            .font(.subheadline)
                            .lineLimit(1)
                    }
                }
                if mapped.drafts.count > 20 {
                    Text("…và \(mapped.drafts.count - 20) dòng nữa")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(mapped.errors.prefix(5), id: \.rowNumber) { error in
                    Text("Dòng \(error.rowNumber): \(error.reason)")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                if mapped.errors.count > 5 {
                    Text("…và \(mapped.errors.count - 5) dòng lỗi nữa")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        } header: {
            Text("Xem trước")
        }

        Section {
            Button {
                goToConfirm()
            } label: {
                Label("Tiếp tục", systemImage: "arrow.right.circle.fill")
            }
            .disabled(!mapping.isComplete)
        }
    }

    private func columnPicker(
        _ title: String,
        keyPath: WritableKeyPath<CSVImportMapping, Int?>
    ) -> some View {
        Picker(title, selection: Binding(
            get: { mapping[keyPath: keyPath] },
            set: { mapping[keyPath: keyPath] = $0 }
        )) {
            Text("—").tag(Int?.none)
            ForEach(0 ..< (document?.headers.count ?? 0), id: \.self) { i in
                let name = (document?.headers[i] ?? "")
                    .trimmingCharacters(in: .whitespaces)
                Text(name.isEmpty ? "Cột \(i + 1)" : name).tag(Optional(i))
            }
        }
    }

    // MARK: - Step 3: summary + import

    @ViewBuilder
    private var confirmSections: some View {
        let totalIn = importable.reduce(Int64(0)) {
            $0 + ($1.signedAmount > 0 ? $1.signedAmount : 0)
        }
        let totalOut = importable.reduce(Int64(0)) {
            // Int64.min has no positive counterpart.
            $0 + ($1.signedAmount < 0
                  ? ($1.signedAmount == Int64.min ? Int64.max : -$1.signedAmount)
                  : 0)
        }
        let dates = importable.map(\.date)

        Section {
            LabeledContent("Sẽ nhập", value: "\(importable.count) giao dịch")
            if skippedDuplicates > 0 {
                LabeledContent("Bỏ qua trùng", value: "\(skippedDuplicates)")
            }
            if !mapped.errors.isEmpty {
                LabeledContent("Dòng lỗi", value: "\(mapped.errors.count)")
            }
            HStack {
                Text("Tổng tiền vào")
                Spacer()
                AmountText(amount: totalIn, kind: .income)
            }
            HStack {
                Text("Tổng tiền ra")
                Spacer()
                AmountText(amount: totalOut, kind: .expense)
            }
            if let from = dates.min(), let to = dates.max() {
                LabeledContent(
                    "Khoảng ngày",
                    value: "\(AppDateFormat.shortDate(from)) – \(AppDateFormat.shortDate(to))")
            }
        } header: {
            Text("Tóm tắt")
        } footer: {
            Text("Giao dịch đã nhập trước đó (cùng số tham chiếu hoặc cùng nội dung) được bỏ qua tự động.")
        }

        if !mapped.errors.isEmpty {
            Section {
                ForEach(mapped.errors.prefix(30), id: \.rowNumber) { error in
                    Text("Dòng \(error.rowNumber): \(error.reason)")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                if mapped.errors.count > 30 {
                    Text("…và \(mapped.errors.count - 30) dòng lỗi nữa")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Dòng không đọc được")
            }
        }

        Section {
            Button {
                performImport()
            } label: {
                Label("Nhập \(importable.count) giao dịch",
                      systemImage: "tray.and.arrow.down.fill")
            }
            .disabled(importable.isEmpty)
        }
    }

    // MARK: - Flow

    private func handleFile(_ result: Result<URL, Error>) {
        switch result {
        case .failure:
            notice = CSVImportNotice(message: "Không mở được tệp đã chọn.")
        case .success(let url):
            do {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                let document = try CSVImportDocument(
                    fileName: url.lastPathComponent, data: data)
                startMapping(document)
            } catch let error as CSVImportDocumentError {
                notice = CSVImportNotice(message: error.message)
            } catch {
                notice = CSVImportNotice(message: "Không đọc được tệp đã chọn.")
            }
        }
    }

    /// Auto-guess → overlay the account's remembered mapping → detect the
    /// date and number formats from the guessed columns.
    private func startMapping(_ document: CSVImportDocument) {
        self.document = document
        var guessed = CSVImportDetector.guessMapping(headers: document.headers)
        let saved = selectedAccount.flatMap { mappingStore.mapping(for: $0.id) }
        if let saved {
            guessed = saved.resolved(headers: document.headers, fallback: guessed)
        } else {
            // Nothing remembered yet — detect formats from the samples.
            if let dateColumn = guessed.dateColumn,
               let detected = CSVImportDetector.detectDateFormat(
                   samples(in: document, column: dateColumn)) {
                guessed.dateFormat = detected
            }
            let columns = [guessed.amountColumn, guessed.moneyOutColumn,
                           guessed.moneyInColumn].compactMap { $0 }
            guessed.numberFormat = CSVImportDetector.detectNumberFormat(
                columns.flatMap { samples(in: document, column: $0) })
        }
        mapping = guessed
        usePairColumns = guessed.amountColumn == nil
            && (guessed.moneyOutColumn != nil || guessed.moneyInColumn != nil)
        recompute()
        withAnimation { step = .mapping }
    }

    private func samples(in document: CSVImportDocument, column: Int) -> [String] {
        document.rows.prefix(50).compactMap {
            guard $0.cells.indices.contains(column) else { return nil }
            return $0.cells[column]
        }
    }

    private func recompute() {
        guard let document, mapping.isComplete else {
            mapped = .init(drafts: [], errors: [])
            return
        }
        mapped = CSVImportMapper.map(rows: document.rows, mapping: mapping)
    }

    private func goToConfirm() {
        guard let account = selectedAccount, let document else { return }
        mappingStore.saveMapping(
            CSVImportSavedMapping(from: mapping, headers: document.headers),
            for: account.id)
        let prepared = importer.prepare(drafts: mapped.drafts, account: account)
        importable = prepared.importable
        skippedDuplicates = prepared.skipped
        withAnimation { step = .confirm }
    }

    private func performImport() {
        guard let account = selectedAccount else { return }
        do {
            let outcome = try importer.import(
                drafts: mapped.drafts, into: account)
            var message = "Đã nhập \(outcome.inserted) giao dịch"
                + " vào \"\(account.name)\"."
            if outcome.skippedDuplicates > 0 {
                message += " Bỏ qua \(outcome.skippedDuplicates) dòng trùng."
            }
            notice = CSVImportNotice(message: message)
        } catch {
            notice = CSVImportNotice(
                message: "Nhập thất bại: \(error.localizedDescription)")
        }
        document = nil
        recompute()
        refreshBatch()
        withAnimation { step = .source }
    }

    private func performUndo() {
        guard let account = selectedAccount else { return }
        let deleted = importer.undoLastBatch(for: account)
        notice = CSVImportNotice(
            message: deleted > 0
                ? "Đã xoá \(deleted) giao dịch của lần nhập gần nhất."
                : "Không tìm thấy giao dịch nào của lần nhập gần nhất.")
        refreshBatch()
    }

    private func refreshBatch() {
        lastBatch = selectedAccount.flatMap { batchStore.batch(for: $0.id) }
    }

    private var noticePresented: Binding<Bool> {
        Binding(
            get: { notice != nil },
            set: { if !$0 { notice = nil } }
        )
    }
}

/// A transient result/error message shown in the generic alert.
private struct CSVImportNotice: Identifiable {
    let id = UUID()
    let message: String
}

#Preview {
    let container = try! AppModelContainer.make(inMemory: true)
    try! SeedData.seedIfNeeded(context: ModelContext(container))
    return NavigationStack {
        CSVImportView()
    }
    .modelContainer(container)
}
