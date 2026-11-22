import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Backup, CSV export and restore — the screen that keeps data safe while
/// everything lives only on this phone. Pushed inside an existing
/// NavigationStack (from Settings); it must not wrap itself in one.
struct BackupView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var accounts: [Account]
    @Query private var categories: [LedgerCategory]
    @Query private var businesses: [Business]
    @Query(sort: \LedgerTransaction.date) private var transactions: [LedgerTransaction]

    /// Seconds since 1970 of the last successful JSON backup; 0 = never.
    @AppStorage("backupLastExportAt") private var lastExportTimestamp = 0.0

    @State private var exportDocument = BackupExportDocument()
    @State private var exportContentType: UTType = .json
    @State private var exportFilename = ""
    /// Only a JSON backup counts as "the last export" for the reminder —
    /// a CSV is for spreadsheets and cannot be restored.
    @State private var exportIsBackup = false
    @State private var showsExporter = false
    @State private var showsImporter = false

    @State private var importedDocument: BackupDocument?
    @State private var showsImportSummary = false
    @State private var showsReplaceConfirm = false
    @State private var notice: BackupNotice?

    @State private var limitsCSVRange = false
    @State private var csvFrom = BackupView.firstOfCurrentMonth()
    @State private var csvTo = Date.now

    var body: some View {
        Form {
            statusSection
            backupSection
            csvSection
            restoreSection
        }
        .navigationTitle("Sao lưu & Khôi phục")
        .fileExporter(
            isPresented: $showsExporter,
            document: exportDocument,
            contentType: exportContentType,
            defaultFilename: exportFilename
        ) { result in
            if case .success = result, exportIsBackup {
                lastExportTimestamp = Date.now.timeIntervalSince1970
            }
        }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                importBackup(from: url)
            case .failure:
                notice = BackupNotice(message: "Không mở được tệp đã chọn.")
            }
        }
        .alert(
            "Khôi phục bản sao lưu",
            isPresented: $showsImportSummary,
            presenting: importedDocument
        ) { document in
            Button("Gộp vào dữ liệu hiện có") {
                performRestore(document, mode: .merge)
            }
            Button("Thay thế toàn bộ", role: .destructive) {
                showsImportSummary = false
                showsReplaceConfirm = true
            }
            Button("Huỷ", role: .cancel) {
                importedDocument = nil
            }
        } message: { document in
            Text(summaryText(document))
        }
        .alert("Thay thế toàn bộ dữ liệu?", isPresented: $showsReplaceConfirm) {
            Button("Xoá & khôi phục", role: .destructive) {
                if let document = importedDocument {
                    performRestore(document, mode: .replace)
                }
            }
            Button("Huỷ", role: .cancel) {
                importedDocument = nil
            }
        } message: {
            Text("Toàn bộ dữ liệu hiện có sẽ bị xoá và thay bằng nội dung bản sao lưu. Thao tác này không thể hoàn tác.")
        }
        .alert("Sao lưu & Khôi phục", isPresented: noticePresented, presenting: notice) { _ in
            Button("OK") {}
        } message: { notice in
            Text(notice.message)
        }
    }

    // MARK: - Sections

    private var statusSection: some View {
        Section {
            LabeledContent("Tài khoản", value: "\(accounts.count)")
            LabeledContent("Danh mục", value: "\(categories.count)")
            LabeledContent("Doanh nghiệp", value: "\(businesses.count)")
            LabeledContent("Giao dịch", value: "\(transactions.count)")
            LabeledContent("Sao lưu gần nhất", value: lastExportText)
            if BackupReminder.isDue(lastExport: lastExport, now: .now) {
                Label(reminderText, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Dữ liệu hiện tại")
        }
    }

    private var backupSection: some View {
        Section {
            Button {
                exportBackupJSON()
            } label: {
                Label("Xuất bản sao lưu (JSON)", systemImage: "square.and.arrow.up")
            }
        } header: {
            Text("Sao lưu toàn bộ")
        } footer: {
            Text("Tệp JSON chứa toàn bộ tài khoản, danh mục, doanh nghiệp và giao dịch. Dữ liệu chỉ nằm trên điện thoại này — hãy giữ tệp ở nơi an toàn.")
        }
    }

    private var csvSection: some View {
        Section {
            Toggle("Giới hạn khoảng ngày", isOn: $limitsCSVRange)
            if limitsCSVRange {
                DatePicker("Từ ngày", selection: $csvFrom, displayedComponents: .date)
                DatePicker("Đến ngày", selection: $csvTo, in: csvFrom..., displayedComponents: .date)
            }
            Button {
                exportCSV()
            } label: {
                Label("Xuất CSV (\(csvTransactions.count) giao dịch)", systemImage: "tablecells")
            }
            .disabled(csvTransactions.isEmpty)
        } header: {
            Text("Xuất cho Excel")
        } footer: {
            Text("Tệp CSV UTF-8 gồm ngày, loại, số tiền, tài khoản và ghi chú — mở được trong Excel, Numbers và Google Sheets.")
        }
    }

    private var restoreSection: some View {
        Section {
            Button {
                showsImporter = true
            } label: {
                Label("Khôi phục từ tệp sao lưu…", systemImage: "doc.badge.arrow.down")
            }
        } header: {
            Text("Khôi phục")
        } footer: {
            Text("Chọn tệp JSON đã xuất trước đó. Bạn sẽ xem tóm tắt nội dung tệp trước khi quyết định gộp hay thay thế.")
        }
    }

    // MARK: - Status helpers

    private var lastExport: Date? {
        lastExportTimestamp > 0 ? Date(timeIntervalSince1970: lastExportTimestamp) : nil
    }

    private var lastExportText: String {
        guard let lastExport else { return "Chưa từng sao lưu" }
        return AppDateFormat.dayHeader(lastExport, now: .now) + " " + AppDateFormat.time(lastExport)
    }

    private var reminderText: String {
        if lastExport == nil {
            return "Bạn chưa sao lưu lần nào. Toàn bộ dữ liệu chỉ nằm trên điện thoại này — hãy xuất một bản sao lưu ngay."
        }
        return "Lần sao lưu gần nhất đã hơn 7 ngày trước. Hãy xuất một bản sao lưu mới để tránh mất dữ liệu."
    }

    // MARK: - Export

    private func exportBackupJSON() {
        do {
            exportDocument = BackupExportDocument(data: try BackupCodec.encode(context: modelContext))
            exportContentType = .json
            exportFilename = "AMFinance-backup-\(BackupCodec.fileStamp(.now))"
            exportIsBackup = true
            showsExporter = true
        } catch {
            notice = BackupNotice(message: "Không tạo được bản sao lưu: \(error.localizedDescription)")
        }
    }

    /// Transactions selected for the CSV: all of them, or the Vietnam-day
    /// range from the pickers when the toggle is on.
    private var csvTransactions: [LedgerTransaction] {
        guard limitsCSVRange else { return transactions }
        let calendar = AppCalendar.vietnam
        let start = calendar.startOfDay(for: csvFrom)
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: csvTo)) ?? csvTo
        return transactions.filter { $0.date >= start && $0.date < end }
    }

    private func exportCSV() {
        let rows = csvTransactions.map(BackupCSVRow.init)
        exportDocument = BackupExportDocument(data: BackupCSV.data(rows: rows))
        exportContentType = .commaSeparatedText
        exportFilename = "AMFinance-giao-dich-\(BackupCodec.fileStamp(.now))"
        exportIsBackup = false
        showsExporter = true
    }

    // MARK: - Restore

    private func importBackup(from url: URL) {
        do {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let document = try BackupCodec.decode(try Data(contentsOf: url))
            importedDocument = document
            showsImportSummary = true
        } catch let error as BackupError {
            notice = BackupNotice(message: error.errorDescription ?? "Tệp sao lưu không hợp lệ.")
        } catch {
            notice = BackupNotice(message: "Không đọc được tệp đã chọn.")
        }
    }

    private func summaryText(_ document: BackupDocument) -> String {
        let date = AppDateFormat.dayHeader(document.exportedAt, now: .now)
            + " " + AppDateFormat.time(document.exportedAt)
        return """
        Xuất lúc: \(date) · phiên bản \(document.appVersion)
        \(document.accounts.count) tài khoản · \(document.categories.count) danh mục · \(document.businesses.count) doanh nghiệp · \(document.transactions.count) giao dịch
        """
    }

    private func performRestore(_ document: BackupDocument, mode: BackupRestoreMode) {
        defer { importedDocument = nil }
        do {
            let result = try BackupRestorer.restore(document, mode: mode, into: modelContext)
            notice = BackupNotice(
                message: "Khôi phục xong: \(result.inserted) mục mới, \(result.updated) cập nhật, \(result.skipped) bỏ qua."
            )
        } catch let error as BackupError {
            notice = BackupNotice(message: error.errorDescription ?? "Khôi phục thất bại.")
        } catch {
            notice = BackupNotice(message: "Khôi phục thất bại: \(error.localizedDescription)")
        }
    }

    private var noticePresented: Binding<Bool> {
        Binding(
            get: { notice != nil },
            set: { if !$0 { notice = nil } }
        )
    }

    private static func firstOfCurrentMonth() -> Date {
        let calendar = AppCalendar.vietnam
        return calendar.date(from: calendar.dateComponents([.year, .month], from: .now)) ?? .now
    }
}

/// The exported file handed to `.fileExporter`. Readable types cover both
/// kinds this screen writes so one document type serves JSON and CSV.
struct BackupExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .commaSeparatedText] }

    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// A transient result/error message shown in the generic alert.
struct BackupNotice: Identifiable {
    let id = UUID()
    let message: String
}

/// The >7-day stale-backup reminder rule, kept tiny and testable.
enum BackupReminder {
    static func isDue(lastExport: Date?, now: Date) -> Bool {
        guard let lastExport else { return true }
        return now.timeIntervalSince(lastExport) > 7 * 86_400
    }
}

#Preview {
    let container = try! AppModelContainer.make(inMemory: true)
    try! SeedData.seedIfNeeded(context: ModelContext(container))
    return NavigationStack {
        BackupView()
    }
    .modelContainer(container)
}
