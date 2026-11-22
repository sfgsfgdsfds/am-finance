import Testing
import SwiftData
import Foundation
import FinanceCore
@testable import AMFinance

struct SettingsTests {

    // MARK: - SettingsNameNormalizer

    @Test func foldIgnoresCaseDiacriticsAndWhitespace() {
        #expect(SettingsNameNormalizer.fold("Ăn uống") == "an uong")
        #expect(SettingsNameNormalizer.fold("an uong") == "an uong")
        #expect(SettingsNameNormalizer.fold("  ĂN   UỐNG ") == "an uong")
        // "đ" does not decompose in Unicode — folded by hand.
        #expect(SettingsNameNormalizer.fold("Đi chơi") == "di choi")
        #expect(SettingsNameNormalizer.fold("Đi chơi") == SettingsNameNormalizer.fold("di choi"))
    }

    // MARK: - CategoryDraft

    @Test func categoryDraftRequiresTrimmedName() {
        #expect(!CategoryDraft().isValid)
        #expect(!CategoryDraft(name: "   ").isValid)
        #expect(CategoryDraft(name: " Ăn uống ").isValid)
        #expect(CategoryDraft(name: " Ăn uống ").trimmedName == "Ăn uống")
    }

    @Test func categoryDraftDetectsDuplicatesWithinSameKind() {
        let food = LedgerCategory(name: "Ăn uống", kind: .expense)
        let salary = LedgerCategory(name: "Lương", kind: .income)
        let all = [food, salary]

        // Same kind, different case/accents → duplicate.
        #expect(CategoryDraft(name: "an uong", kind: .expense).duplicateName(among: all))
        #expect(CategoryDraft(name: "ĂN UỐNG", kind: .expense).duplicateName(among: all))
        // Same spelling but the other kind → allowed.
        #expect(!CategoryDraft(name: "an uong", kind: .income).duplicateName(among: all))
        // Excluding itself → editing a category does not flag it.
        #expect(!CategoryDraft(name: "an uong", kind: .expense)
            .duplicateName(among: all, excludingID: food.id))
        // Blank names never count as duplicates.
        #expect(!CategoryDraft(name: "  ", kind: .expense).duplicateName(among: all))
    }

    @Test func categoryDraftMapsToAndFromModel() {
        let category = LedgerCategory(
            name: "Đi chơi", kind: .expense,
            icon: "ticket.fill", colorHex: "FF2D55", sortOrder: 3
        )
        let draft = CategoryDraft(category: category)
        #expect(draft == CategoryDraft(
            name: "Đi chơi", kind: .expense, icon: "ticket.fill", colorHex: "FF2D55"
        ))

        var edited = draft
        edited.name = "  Đi chơi mới "
        edited.colorHex = "0A84FF"
        edited.kind = .income
        edited.apply(to: category)
        #expect(category.name == "Đi chơi mới")
        #expect(category.colorHex == "0A84FF")
        // apply never rewrites kind or ordering.
        #expect(category.kind == .expense)
        #expect(category.sortOrder == 3)

        var created = draft
        created.kind = .income
        let newCategory = created.makeCategory(sortOrder: 7)
        #expect(newCategory.name == "Đi chơi")
        #expect(newCategory.kind == .income)
        #expect(newCategory.icon == "ticket.fill")
        #expect(newCategory.sortOrder == 7)
    }

    // MARK: - BusinessDraft

    @Test func businessDraftRequiresTrimmedName() {
        #expect(!BusinessDraft().isValid)
        #expect(!BusinessDraft(name: " \n ").isValid)
        #expect(BusinessDraft(name: " Làm web ").isValid)
        #expect(BusinessDraft(name: " Làm web ").trimmedName == "Làm web")
    }

    @Test func businessDraftDetectsDuplicatesIgnoringCaseAndAccents() {
        let web = Business(name: "Làm web")
        let apartment = Business(name: "Căn hộ dịch vụ")
        let all = [web, apartment]

        #expect(BusinessDraft(name: "lam web").duplicateName(among: all))
        #expect(BusinessDraft(name: "LÀM WEB").duplicateName(among: all))
        #expect(!BusinessDraft(name: "lam web").duplicateName(among: all, excludingID: web.id))
        #expect(!BusinessDraft(name: "Chạy quảng cáo").duplicateName(among: all))
    }

    @Test func businessDraftMapsToAndFromModel() {
        let business = Business(
            name: "Căn hộ dịch vụ", icon: "building.2.fill",
            colorHex: "30B0C7", note: " 2 phòng ", sortOrder: 1
        )
        let draft = BusinessDraft(business: business)
        #expect(draft == BusinessDraft(
            name: "Căn hộ dịch vụ", icon: "building.2.fill",
            colorHex: "30B0C7", note: " 2 phòng "
        ))

        var edited = draft
        edited.name = " Căn hộ dịch vụ Q7 "
        edited.apply(to: business)
        #expect(business.name == "Căn hộ dịch vụ Q7")
        #expect(business.note == "2 phòng")
        #expect(business.sortOrder == 1)

        let created = draft.makeBusiness(sortOrder: 4)
        #expect(created.name == "Căn hộ dịch vụ")
        #expect(created.note == "2 phòng")
        #expect(created.sortOrder == 4)
        #expect(!created.isArchived)
    }

    // MARK: - SettingsReorder

    @Test func reorderMovesAndRenumbers() {
        let a = LedgerCategory(name: "A", kind: .expense, sortOrder: 0)
        let b = LedgerCategory(name: "B", kind: .expense, sortOrder: 1)
        let c = LedgerCategory(name: "C", kind: .expense, sortOrder: 2)

        // Drag the first row to the end.
        let reordered = SettingsReorder.moved([a, b, c], from: IndexSet(integer: 0), to: 3)
        #expect(reordered.map(\.name) == ["B", "C", "A"])
        SettingsReorder.renumber(reordered, sortOrder: \.sortOrder)
        #expect(b.sortOrder == 0 && c.sortOrder == 1 && a.sortOrder == 2)

        // Drag the last row back to the front.
        let again = SettingsReorder.moved(reordered, from: IndexSet(integer: 2), to: 0)
        #expect(again.map(\.name) == ["A", "B", "C"])
        SettingsReorder.renumber(again, sortOrder: \.sortOrder)
        #expect(a.sortOrder == 0 && b.sortOrder == 1 && c.sortOrder == 2)
    }

    @Test func reorderMultiRowMove() {
        let items = (0..<5).map { LedgerCategory(name: "C\($0)", kind: .expense, sortOrder: $0) }
        // Move rows 0 and 1 after row 3.
        let reordered = SettingsReorder.moved(items, from: IndexSet([0, 1]), to: 4)
        #expect(reordered.map(\.name) == ["C2", "C3", "C0", "C1", "C4"])
    }

    // MARK: - SettingsDeleteRule

    @Test func deleteRuleAllowsDeleteOnlyWhenUnused() {
        #expect(SettingsDeleteRule.decision(transactionCount: 0) == .delete)
        #expect(SettingsDeleteRule.decision(transactionCount: 1) == .archiveOnly(transactionCount: 1))
        #expect(SettingsDeleteRule.decision(transactionCount: 7) == .archiveOnly(transactionCount: 7))
    }

    @MainActor @Test func deleteRuleCountsRealCategoryTransactions() throws {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let category = LedgerCategory(name: "Ăn uống", kind: .expense)
        let account = Account(name: "Tiền mặt", kind: .cash)
        context.insert(category)
        context.insert(account)
        try context.save()

        #expect(SettingsDeleteRule.decision(
            transactionCount: category.transactions?.count ?? 0) == .delete)

        context.insert(LedgerTransaction(
            kind: .expense, amount: 10_000, account: account, category: category))
        try context.save()

        #expect(SettingsDeleteRule.decision(
            transactionCount: category.transactions?.count ?? 0) == .archiveOnly(transactionCount: 1))
    }

    @MainActor @Test func deleteRuleCountsRealBusinessTransactions() throws {
        let context = ModelContext(try AppModelContainer.make(inMemory: true))
        let business = Business(name: "Làm web")
        let account = Account(name: "Tiền mặt", kind: .cash)
        context.insert(business)
        context.insert(account)
        try context.save()

        #expect(SettingsDeleteRule.decision(
            transactionCount: business.transactions?.count ?? 0) == .delete)

        context.insert(LedgerTransaction(
            kind: .income, amount: 5_000_000, account: account, business: business))
        try context.save()

        #expect(SettingsDeleteRule.decision(
            transactionCount: business.transactions?.count ?? 0) == .archiveOnly(transactionCount: 1))
    }

    // MARK: - SettingsAbout

    @Test func aboutVersionText() {
        #expect(SettingsAbout.versionText(shortVersion: "1.0", build: "23") == "1.0 (23)")
        #expect(SettingsAbout.versionText(shortVersion: "1.0", build: "1.0") == "1.0")
        #expect(SettingsAbout.versionText(shortVersion: "1.0", build: nil) == "1.0")
        #expect(SettingsAbout.versionText(shortVersion: "1.0", build: "") == "1.0")
        #expect(SettingsAbout.versionText(shortVersion: nil, build: "23") == "23")
        #expect(SettingsAbout.versionText(shortVersion: nil, build: nil) == "—")
    }
}
