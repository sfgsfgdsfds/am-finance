import Testing
import Foundation
import SwiftData
import FinanceCore
@testable import AMFinance

/// CSV statement import: the RFC 4180 parser, encoding/delimiter/header
/// detection, header-name guessing, date and number formats, row mapping
/// with per-row errors, stable-id dedupe (re-import is a no-op, identical
/// rows both kept), rule application and the undoable batch. Everything
/// runs on an in-memory store — no files, no real UserDefaults.
@Suite(.serialized)
@MainActor
struct CSVImportTests {

    private let calendar = AppCalendar.vietnam

    // MARK: - Scaffolding

    private func makeContext() throws -> ModelContext {
        ModelContext(try AppModelContainer.make(inMemory: true))
    }

    private func document(
        _ text: String, name: String = "sao-ke.csv"
    ) throws -> CSVImportDocument {
        try CSVImportDocument(fileName: name, data: Data(text.utf8))
    }

    private func day(
        _ year: Int, _ month: Int, _ dayOfMonth: Int,
        _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0
    ) -> Date {
        calendar.date(from: DateComponents(
            year: year, month: month, day: dayOfMonth,
            hour: hour, minute: minute, second: second))!
    }

    @discardableResult
    private func account(
        in context: ModelContext, name: String = "Ngân hàng ACB"
    ) -> Account {
        let account = Account(name: name, kind: .bank)
        context.insert(account)
        return account
    }

    private func importer(
        context: ModelContext,
        rules: [WalletSyncRule] = [],
        states: WalletSyncInMemoryStateStore = WalletSyncInMemoryStateStore(),
        batches: CSVImportInMemoryBatchStore = CSVImportInMemoryBatchStore()
    ) -> CSVImportImporter {
        CSVImportImporter(
            context: context,
            ruleStore: WalletSyncInMemoryRuleStore(rules: rules),
            stateStore: states,
            batchStore: batches)
    }

    private func allTransactions(
        in context: ModelContext
    ) throws -> [LedgerTransaction] {
        try context.fetch(FetchDescriptor<LedgerTransaction>(
            sortBy: [SortDescriptor(\.date), SortDescriptor(\.createdAt)]))
    }

    /// A guessed mapping with the formats pinned so tests stay literal.
    private func guessedMapping(
        for document: CSVImportDocument,
        dateFormat: CSVImportDateFormat = .dayMonthYearSlash,
        numberFormat: CSVImportNumberFormatStyle = .vietnamese
    ) -> CSVImportMapping {
        var mapping = CSVImportDetector.guessMapping(headers: document.headers)
        mapping.dateFormat = dateFormat
        mapping.numberFormat = numberFormat
        return mapping
    }

    // MARK: - Parser

    @Test func parserHandlesQuotesEmbeddedDelimitersNewlinesAndCRLF() {
        let text = "a,b,c\r\n\"x,y\",\"line1\nline2\",\"he said \"\"hi\"\"\"\r\n1,2,3"
        let rows = CSVImportParser.parse(text, delimiter: .comma)
        #expect(rows == [
            ["a", "b", "c"],
            ["x,y", "line1\nline2", "he said \"hi\""],
            ["1", "2", "3"],
        ])
    }

    @Test func parserHandlesCRAndLFOnlyAndTrailingEmptyFields() {
        #expect(CSVImportParser.parse("a,b\rc,d", delimiter: .comma) == [["a", "b"], ["c", "d"]])
        #expect(CSVImportParser.parse("a,b\n", delimiter: .comma) == [["a", "b"]])
        #expect(CSVImportParser.parse("a,,c\n", delimiter: .comma) == [["a", "", "c"]])
        #expect(CSVImportParser.parse("", delimiter: .comma) == [])
    }

    @Test func documentReadsUTF8BOMSemicolonAndTab() throws {
        let bomData = Data([0xEF, 0xBB, 0xBF])
            + "Ngày;Mô tả;Ghi nợ;Ghi có\r\n22/11/2026;AN UONG;100.000;\r\n".utf8
        let doc = try CSVImportDocument(fileName: "acb.csv", data: bomData)
        #expect(doc.delimiter == .semicolon)
        #expect(doc.headers == ["Ngày", "Mô tả", "Ghi nợ", "Ghi có"])
        #expect(doc.rows.count == 1)
        #expect(doc.rows[0].cells[1] == "AN UONG")

        let tab = try document("Ngày\tMô tả\tSố tiền\n22/11/2026\tAn uong\t-100000\n")
        #expect(tab.delimiter == .tab)
        #expect(tab.headers.count == 3)
    }

    @Test func documentSkipsPreambleBeforeHeader() throws {
        let doc = try document("""
        NGAN HANG ABC
        SAO KE TAI KHOAN 0123456789
        Tu ngay 01/11/2026 den 30/11/2026

        Ngày,Mô tả,Ghi nợ,Ghi có
        22/11/2026,AN UONG,100000,
        23/11/2026,LUONG,,15000000
        """)
        #expect(doc.delimiter == .comma)
        #expect(doc.headers == ["Ngày", "Mô tả", "Ghi nợ", "Ghi có"])
        #expect(doc.rows.count == 2)
        #expect(doc.rows[0].number == 6)  // 1-based table row
    }

    @Test func documentRejectsEmptyAndTablelessFiles() {
        #expect {
            try CSVImportDocument(fileName: "e.csv", data: Data())
        } throws: { error in
            (error as? CSVImportDocumentError) == .emptyFile
        }
        #expect {
            try document("abc\ndef\nghi\n")
        } throws: { error in
            (error as? CSVImportDocumentError) == .headerNotFound
        }
        // A header with no data rows after it also fails to map.
        #expect {
            try document("Ngày,Mô tả,Ghi nợ,Ghi có\n")
        } throws: { error in
            (error as? CSVImportDocumentError) == .headerNotFound
        }
    }

    @Test func decodeHandlesUTF16WithAndWithoutBOM() throws {
        let text = "Ngày,Mô tả,Số tiền\r\n22/11/2026,An uong,-100000\r\n"
        // .utf16 emits a BOM; .utf16LittleEndian does not.
        let withBOM = try #require(text.data(using: .utf16))
        let decodedBOM = CSVImportDetector.decode(withBOM)
        #expect(decodedBOM.contains("Ngày"))
        let doc = try CSVImportDocument(fileName: "utf16.csv", data: withBOM)
        #expect(doc.headers.count == 3)

        let noBOM = try #require(text.data(using: .utf16LittleEndian))
        #expect(CSVImportDetector.decode(noBOM).contains("Ngày"))
    }

    // MARK: - Date + number formats

    @Test func parsesEachDateFormat() {
        #expect(CSVImportDetector.parseDate(
            "22/11/2026", format: .dayMonthYearSlash) == day(2026, 11, 22))
        #expect(CSVImportDetector.parseDate(
            "1/2/2026", format: .dayMonthYearSlash) == day(2026, 2, 1))
        #expect(CSVImportDetector.parseDate(
            "22-11-2026", format: .dayMonthYearDash) == day(2026, 11, 22))
        #expect(CSVImportDetector.parseDate(
            "22.11.2026", format: .dayMonthYearDot) == day(2026, 11, 22))
        #expect(CSVImportDetector.parseDate(
            "2026-11-22", format: .yearMonthDayDash) == day(2026, 11, 22))
        #expect(CSVImportDetector.parseDate(
            "2026/11/22", format: .yearMonthDaySlash) == day(2026, 11, 22))
        #expect(CSVImportDetector.parseDate(
            "22/11/26", format: .dayMonthYearSlashShort) == day(2026, 11, 22))
        // Optional time part, space or T separated.
        #expect(CSVImportDetector.parseDate(
            "22/11/2026 14:05", format: .dayMonthYearSlash)
            == day(2026, 11, 22, 14, 5))
        #expect(CSVImportDetector.parseDate(
            "2026-11-22T14:05:30", format: .yearMonthDayDash)
            == day(2026, 11, 22, 14, 5, 30))
        // Invalid dates are rejected, not normalized.
        #expect(CSVImportDetector.parseDate(
            "31/02/2026", format: .dayMonthYearSlash) == nil)
        #expect(CSVImportDetector.parseDate(
            "22/13/2026", format: .dayMonthYearSlash) == nil)
        #expect(CSVImportDetector.parseDate(
            "abc", format: .dayMonthYearSlash) == nil)
    }

    @Test func detectsTheDateFormatFromSamples() {
        #expect(CSVImportDetector.detectDateFormat(
            ["22/11/2026", "23/11/2026"]) == .dayMonthYearSlash)
        #expect(CSVImportDetector.detectDateFormat(
            ["2026-11-22 10:00", "2026-11-23"]) == .yearMonthDayDash)
        #expect(CSVImportDetector.detectDateFormat(
            ["22-11-2026"]) == .dayMonthYearDash)
        #expect(CSVImportDetector.detectDateFormat(["không phải ngày"]) == nil)
    }

    @Test func parsesBothNumberFormatsAndNegativeStyles() {
        // Vietnamese "." thousands, "," decimal.
        #expect(CSVImportDetector.parseAmount(
            "1.234.567", style: .vietnamese) == 1_234_567)
        #expect(CSVImportDetector.parseAmount(
            "1.234.567,5", style: .vietnamese) == 1_234_568)
        #expect(CSVImportDetector.parseAmount(
            "1.000đ", style: .vietnamese) == 1_000)
        // International "," thousands, "." decimal.
        #expect(CSVImportDetector.parseAmount(
            "1,234,567", style: .international) == 1_234_567)
        #expect(CSVImportDetector.parseAmount(
            "1,234,567.5", style: .international) == 1_234_568)
        // Parentheses, trailing and leading minus, plus sign.
        #expect(CSVImportDetector.parseAmount(
            "(1.234.567)", style: .vietnamese) == -1_234_567)
        #expect(CSVImportDetector.parseAmount(
            "1.234.567-", style: .vietnamese) == -1_234_567)
        #expect(CSVImportDetector.parseAmount(
            "-1,234,567", style: .international) == -1_234_567)
        #expect(CSVImportDetector.parseAmount(
            "+250.000", style: .vietnamese) == 250_000)
        // Bare digits and currency marks.
        #expect(CSVImportDetector.parseAmount("150000", style: .vietnamese) == 150_000)
        #expect(CSVImportDetector.parseAmount("150000 VND", style: .vietnamese) == 150_000)
        // Non-numeric input is nil.
        #expect(CSVImportDetector.parseAmount("abc", style: .vietnamese) == nil)
        #expect(CSVImportDetector.parseAmount("", style: .vietnamese) == nil)
        #expect(CSVImportDetector.parseAmount("1,2,3", style: .vietnamese) == nil)
    }

    @Test func detectsTheNumberFormatFromSamples() {
        // A VN file groups with "." — every sample is a whole number only
        // under .vietnamese.
        #expect(CSVImportDetector.detectNumberFormat(
            ["1.234.567", "2.000", "50.000"]) == .vietnamese)
        // A US-style file groups with "," — "12,345" would read as a
        // decimal under .vietnamese, so .international wins.
        #expect(CSVImportDetector.detectNumberFormat(
            ["1,234,567", "12,345", "1,000.50"]) == .international)
        // Bare digits are a tie and default to Vietnamese.
        #expect(CSVImportDetector.detectNumberFormat(
            ["150000", "2000"]) == .vietnamese)
    }

    // MARK: - Header guessing

    @Test func guessesVietnameseHeadersWithAndWithoutDiacritics() {
        for headers in [
            ["Ngày giao dịch", "Diễn giải", "Ghi nợ", "Ghi có", "Số tham chiếu"],
            ["Ngay giao dich", "Dien giai", "Ghi no", "Ghi co", "So tham chieu"],
        ] {
            let mapping = CSVImportDetector.guessMapping(headers: headers)
            #expect(mapping.dateColumn == 0)
            #expect(mapping.descriptionColumn == 1)
            #expect(mapping.moneyOutColumn == 2)
            #expect(mapping.moneyInColumn == 3)
            #expect(mapping.referenceColumn == 4)
            #expect(mapping.amountColumn == nil)  // pair wins over signed
        }
    }

    @Test func guessesEnglishHeadersAndSingleAmountColumn() {
        let pair = CSVImportDetector.guessMapping(headers: [
            "Transaction Date", "Description", "Debit", "Credit", "Reference Number"])
        #expect(pair.dateColumn == 0)
        #expect(pair.descriptionColumn == 1)
        #expect(pair.moneyOutColumn == 2)
        #expect(pair.moneyInColumn == 3)
        #expect(pair.referenceColumn == 4)

        let single = CSVImportDetector.guessMapping(headers: [
            "Ngày", "Nội dung", "Số tiền"])
        #expect(single.dateColumn == 0)
        #expect(single.descriptionColumn == 1)
        #expect(single.amountColumn == 2)
        #expect(single.moneyOutColumn == nil)
        #expect(single.moneyInColumn == nil)
        #expect(single.isComplete)

        // Prefixed variants still match ("Số tiền ghi nợ").
        let prefixed = CSVImportDetector.guessMapping(headers: [
            "Ngày GD", "Nội dung GD", "Số tiền ghi nợ", "Số tiền ghi có"])
        #expect(prefixed.moneyOutColumn == 2)
        #expect(prefixed.moneyInColumn == 3)
    }

    // MARK: - Mapper

    @Test func mapsDebitCreditPairsAndSingleSignedColumns() throws {
        let pairDoc = try document("""
        Ngày,Mô tả,Ghi nợ,Ghi có
        22/11/2026,AN UONG,150000,
        22/11/2026,LUONG,,15000000
        """)
        var pairMapping = guessedMapping(for: pairDoc)
        pairMapping.moneyOutColumn = 2
        pairMapping.moneyInColumn = 3
        let pair = CSVImportMapper.map(rows: pairDoc.rows, mapping: pairMapping)
        #expect(pair.errors.isEmpty)
        #expect(pair.drafts.map(\.signedAmount) == [-150_000, 15_000_000])
        #expect(pair.drafts[0].date == day(2026, 11, 22))
        #expect(pair.drafts[0].note == "AN UONG")

        let signedDoc = try document("""
        Ngày,Nội dung,Số tiền
        22/11/2026,An uong,-1.500.000
        23/11/2026,Luong,15.000.000
        """)
        var signedMapping = guessedMapping(for: signedDoc)
        signedMapping.amountColumn = 2
        signedMapping.moneyOutColumn = nil
        signedMapping.moneyInColumn = nil
        let signed = CSVImportMapper.map(rows: signedDoc.rows, mapping: signedMapping)
        #expect(signed.errors.isEmpty)
        #expect(signed.drafts.map(\.signedAmount) == [-1_500_000, 15_000_000])
    }

    @Test func flipSignInvertsCardStatementAmounts() throws {
        // Card statements print spending positive and refunds negative —
        // "đảo dấu" turns them into expense and income respectively.
        let doc = try document("""
        Ngày,Nội dung,Số tiền
        22/11/2026,MUA SAM,1.500.000
        23/11/2026,HOAN TIEN,-200.000
        """)
        var mapping = guessedMapping(for: doc)
        mapping.amountColumn = 2
        mapping.flipSign = true
        let mapped = CSVImportMapper.map(rows: doc.rows, mapping: mapping)
        #expect(mapped.drafts.map(\.signedAmount) == [-1_500_000, 200_000])
    }

    @Test func unparseableRowsAreReportedNotImported() throws {
        let doc = try document("""
        Ngày,Nội dung,Số tiền
        22/11/2026,Tốt,100000
        ngày-xấu,Hỏng ngày,100000
        23/11/2026,Hỏng tiền,một trăm nghìn
        24/11/2026,Không tiền,
        """)
        var mapping = guessedMapping(for: doc)
        mapping.amountColumn = 2
        let mapped = CSVImportMapper.map(rows: doc.rows, mapping: mapping)
        #expect(mapped.drafts.count == 1)
        #expect(mapped.errors.count == 3)
        #expect(mapped.errors[0].rowNumber == 3)
        #expect(mapped.errors[0].reason.contains("ngày"))
        #expect(mapped.errors[1].reason.contains("số tiền"))
        #expect(mapped.errors[2].reason == "Thiếu số tiền")
    }

    // MARK: - Dedupe ids

    @Test func hashedIDsAreStableAndDistinctPerOccurrenceAndAccount() {
        let date = day(2026, 11, 22)
        let accountA = UUID()
        let accountB = UUID()
        let first = CSVImportDeduper.hashedID(
            accountID: accountA, date: date, signedAmount: -150_000,
            note: "AN UONG", occurrence: 0)
        #expect(first == CSVImportDeduper.hashedID(
            accountID: accountA, date: date, signedAmount: -150_000,
            note: "AN UONG", occurrence: 0))
        #expect(first != CSVImportDeduper.hashedID(
            accountID: accountA, date: date, signedAmount: -150_000,
            note: "AN UONG", occurrence: 1))
        #expect(first != CSVImportDeduper.hashedID(
            accountID: accountB, date: date, signedAmount: -150_000,
            note: "AN UONG", occurrence: 0))
        #expect(first != CSVImportDeduper.hashedID(
            accountID: accountA, date: date, signedAmount: 150_000,
            note: "AN UONG", occurrence: 0))
        #expect(first.count == 64)
    }

    // MARK: - Import

    @Test func importInsertsLedgerRowsWithExternalMarkers() throws {
        let context = try makeContext()
        let account = account(in: context)
        let doc = try document("""
        Ngày,Mô tả,Ghi nợ,Ghi có,Số tham chiếu
        22/11/2026,AN UONG TRUA,150000,,FT00001
        22/11/2026,LUONG T11,,15000000,FT00002
        """)
        var mapping = guessedMapping(for: doc)
        mapping.moneyOutColumn = 2
        mapping.moneyInColumn = 3
        mapping.referenceColumn = 4
        let mapped = CSVImportMapper.map(rows: doc.rows, mapping: mapping)

        let outcome = try importer(context: context)
            .import(drafts: mapped.drafts, into: account)
        #expect(outcome.inserted == 2)
        #expect(outcome.skippedDuplicates == 0)

        let rows = try allTransactions(in: context)
        #expect(rows.count == 2)
        #expect(rows[0].kind == .expense)
        #expect(rows[0].amount == 150_000)
        #expect(rows[0].note == "AN UONG TRUA")
        #expect(rows[0].needsReview)
        #expect(rows[0].externalSource == "csv")
        #expect(rows[0].externalID == "FT00001")
        #expect(rows[0].account?.id == account.id)
        #expect(rows[1].kind == .income)
        #expect(rows[1].amount == 15_000_000)
        #expect(rows[1].externalID == "FT00002")
        // Signed balance: +15tr −150k.
        #expect(account.balance == 14_850_000)
    }

    @Test func reimportingTheSameFileIsANoOp() throws {
        let context = try makeContext()
        let account = account(in: context)
        let doc = try document("""
        Ngày,Nội dung,Số tiền,Số tham chiếu
        22/11/2026,AN UONG,-150000,FT00001
        22/11/2026,LUONG,15000000,FT00002
        """)
        var mapping = guessedMapping(for: doc)
        mapping.amountColumn = 2
        mapping.referenceColumn = 3
        let mapped = CSVImportMapper.map(rows: doc.rows, mapping: mapping)
        let engine = importer(context: context)

        #expect(try engine.import(drafts: mapped.drafts, into: account).inserted == 2)
        let again = try engine.import(drafts: mapped.drafts, into: account)
        #expect(again.inserted == 0)
        #expect(again.skippedDuplicates == 2)
        #expect(try allTransactions(in: context).count == 2)
    }

    @Test func identicalRowsOnTheSameDayAreBothKept() throws {
        let context = try makeContext()
        let account = account(in: context)
        let doc = try document("""
        Ngày,Nội dung,Số tiền
        22/11/2026,CA PHE,-45000
        22/11/2026,AN TRUA,-120000
        22/11/2026,CA PHE,-45000
        """)
        var mapping = guessedMapping(for: doc)
        mapping.amountColumn = 2
        let mapped = CSVImportMapper.map(rows: doc.rows, mapping: mapping)

        let outcome = try importer(context: context)
            .import(drafts: mapped.drafts, into: account)
        #expect(outcome.inserted == 3)

        let rows = try allTransactions(in: context)
        #expect(rows.count == 3)
        // Occurrence index makes the two identical rows distinct — and
        // stable across re-imports.
        #expect(Set(rows.compactMap(\.externalID)).count == 3)
        let second = try importer(context: context)
            .import(drafts: mapped.drafts, into: account)
        #expect(second.inserted == 0)
        #expect(second.skippedDuplicates == 3)
        #expect(try allTransactions(in: context).count == 3)
    }

    @Test func tombstonedRowsDoNotResurrect() throws {
        let context = try makeContext()
        let account = account(in: context)
        let states = WalletSyncInMemoryStateStore()
        let engine = importer(context: context, states: states)
        let doc = try document("""
        Ngày,Nội dung,Số tiền
        22/11/2026,AN UONG,-150000
        """)
        var mapping = guessedMapping(for: doc)
        mapping.amountColumn = 2
        let mapped = CSVImportMapper.map(rows: doc.rows, mapping: mapping)
        #expect(try engine.import(drafts: mapped.drafts, into: account).inserted == 1)

        // The user deletes the imported row — it is tombstoned.
        let row = try #require(try allTransactions(in: context).first)
        LedgerTransactionDeletion.delete(row, in: context, tombstones: states)
        try context.save()
        #expect(try allTransactions(in: context).isEmpty)

        // Re-importing the same file brings nothing back.
        let outcome = try engine.import(drafts: mapped.drafts, into: account)
        #expect(outcome.inserted == 0)
        #expect(outcome.skippedDuplicates == 1)
        #expect(try allTransactions(in: context).isEmpty)
    }

    @Test func matchingRuleCategorizesAndClearsReview() throws {
        let context = try makeContext()
        try SeedData.seedIfNeeded(context: context)
        let account = account(in: context)
        let food = try #require(
            try context.fetch(FetchDescriptor<LedgerCategory>())
                .first { $0.name == "Ăn uống" })
        let rules = [
            WalletSyncRule(
                keyword: "an uong", direction: .moneyOut,
                action: .category(food.id)),
        ]
        let doc = try document("""
        Ngày,Nội dung,Số tiền
        22/11/2026,AN UONG TRUA,-150000
        22/11/2026,KHAC,-50000
        """)
        var mapping = guessedMapping(for: doc)
        mapping.amountColumn = 2
        let mapped = CSVImportMapper.map(rows: doc.rows, mapping: mapping)

        _ = try importer(context: context, rules: rules)
            .import(drafts: mapped.drafts, into: account)
        let rows = try allTransactions(in: context)
        #expect(rows[0].category?.id == food.id)
        #expect(rows[0].needsReview == false)
        #expect(rows[1].category == nil)
        #expect(rows[1].needsReview == true)
    }

    // MARK: - Undo

    @Test func undoRemovesExactlyTheLastBatch() throws {
        let context = try makeContext()
        let account = account(in: context)
        let states = WalletSyncInMemoryStateStore()
        let batches = CSVImportInMemoryBatchStore()
        let engine = importer(context: context, states: states, batches: batches)

        // A pre-existing manual transaction must survive the undo.
        context.insert(LedgerTransaction(
            kind: .expense, amount: 10_000,
            date: day(2026, 11, 21), note: "Tự ghi", account: account))

        let first = try document("""
        Ngày,Nội dung,Số tiền,Số tham chiếu
        22/11/2026,AN UONG,-150000,FT00001
        """)
        var mapping = guessedMapping(for: first)
        mapping.amountColumn = 2
        mapping.referenceColumn = 3
        let firstMapped = CSVImportMapper.map(rows: first.rows, mapping: mapping)
        _ = try engine.import(drafts: firstMapped.drafts, into: account)

        // Second import replaces the remembered batch.
        let second = try document("""
        Ngày,Nội dung,Số tiền,Số tham chiếu
        23/11/2026,DI CHUYEN,-80000,FT00002
        23/11/2026,MUA SAM,-200000,FT00003
        """)
        let secondMapped = CSVImportMapper.map(rows: second.rows, mapping: mapping)
        _ = try engine.import(drafts: secondMapped.drafts, into: account)
        #expect(try allTransactions(in: context).count == 4)

        // Undo deletes only the second batch — the manual row and the
        // first import stay.
        #expect(engine.undoLastBatch(for: account) == 2)
        let remaining = try allTransactions(in: context)
        #expect(remaining.count == 2)
        #expect(remaining.map(\.note).sorted() == ["AN UONG", "Tự ghi"])

        // Undoing again does nothing.
        #expect(engine.undoLastBatch(for: account) == 0)
    }

    // MARK: - Remembered mapping

    @Test func savedMappingResolvesByHeaderName() {
        let accountID = UUID()
        let store = CSVImportInMemoryMappingStore()
        var mapping = CSVImportMapping()
        mapping.dateColumn = 0
        mapping.amountColumn = 2
        mapping.descriptionColumn = 1
        mapping.referenceColumn = 3
        mapping.dateFormat = .yearMonthDayDash
        mapping.numberFormat = .international
        mapping.flipSign = true
        store.saveMapping(
            CSVImportSavedMapping(
                from: mapping,
                headers: ["Ngày", "Nội dung", "Số tiền", "Mã GD"]),
            for: accountID)

        // Same headers in a different column order still resolve.
        let saved = store.mapping(for: accountID)
        let resolved = saved?.resolved(
            headers: ["Số tiền", "Ngày", "Mã GD", "Nội dung"],
            fallback: CSVImportMapping())
        #expect(resolved?.dateColumn == 1)
        #expect(resolved?.amountColumn == 0)
        #expect(resolved?.descriptionColumn == 3)
        #expect(resolved?.referenceColumn == 2)
        #expect(resolved?.dateFormat == .yearMonthDayDash)
        #expect(resolved?.numberFormat == .international)
        #expect(resolved?.flipSign == true)
        // Unknown headers fall back to the guess.
        let unresolved = saved?.resolved(
            headers: ["Khác", "Hoàn toàn", "Tên lạ"],
            fallback: CSVImportMapping(dateColumn: 1, descriptionColumn: 0))
        #expect(unresolved?.dateColumn == 1)
        #expect(unresolved?.amountColumn == nil)
    }
}
