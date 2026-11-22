import Foundation
import SwiftData
import FinanceCore

/// First-launch seed data. Every seeded row has a fixed UUID, so seeding is
/// idempotent: a re-run only inserts rows that are still missing.
enum SeedData {
    static func seedIfNeeded(context: ModelContext) throws {
        var inserted = false

        let accountIDs = Set(try context.fetch(FetchDescriptor<Account>()).map(\.id))
        for (index, seed) in accountSeeds.enumerated() {
            let id = uuid(seed.id)
            guard !accountIDs.contains(id) else { continue }
            context.insert(Account(
                id: id, name: seed.name, kind: seed.kind,
                icon: seed.icon, colorHex: seed.colorHex, sortOrder: index
            ))
            inserted = true
        }

        let businessIDs = Set(try context.fetch(FetchDescriptor<Business>()).map(\.id))
        for (index, seed) in businessSeeds.enumerated() {
            let id = uuid(seed.id)
            guard !businessIDs.contains(id) else { continue }
            context.insert(Business(
                id: id, name: seed.name, icon: seed.icon,
                colorHex: seed.colorHex, sortOrder: index
            ))
            inserted = true
        }

        let categoryIDs = Set(try context.fetch(FetchDescriptor<LedgerCategory>()).map(\.id))
        for seed in categorySeeds {
            let id = uuid(seed.id)
            guard !categoryIDs.contains(id) else { continue }
            context.insert(LedgerCategory(
                id: id, name: seed.name, kind: seed.kind,
                icon: seed.icon, colorHex: seed.colorHex, sortOrder: seed.sortOrder
            ))
            inserted = true
        }

        if inserted { try context.save() }
    }

    private static func uuid(_ string: String) -> UUID {
        guard let id = UUID(uuidString: string) else {
            preconditionFailure("Invalid seed UUID: \(string)")
        }
        return id
    }

    private struct AccountSeed {
        let id, name, icon, colorHex: String
        let kind: AccountKind
    }

    private struct BusinessSeed {
        let id, name, icon, colorHex: String
    }

    private struct CategorySeed {
        let id, name, icon, colorHex: String
        let kind: CategoryKind
        let sortOrder: Int
    }

    private static let accountSeeds: [AccountSeed] = [
        AccountSeed(id: "5EED0000-0000-4000-8000-000000000001", name: "Tiền mặt",
                    icon: "banknote.fill", colorHex: "34C759", kind: .cash),
    ]

    private static let businessSeeds: [BusinessSeed] = [
        BusinessSeed(id: "5EED0000-0000-4000-8000-000000000101", name: "Căn hộ dịch vụ",
                     icon: "building.2.fill", colorHex: "30B0C7"),
        BusinessSeed(id: "5EED0000-0000-4000-8000-000000000102", name: "Làm web",
                     icon: "chevron.left.forwardslash.chevron.right", colorHex: "0A84FF"),
        BusinessSeed(id: "5EED0000-0000-4000-8000-000000000103", name: "Chạy quảng cáo thuê",
                     icon: "target", colorHex: "FF9F0A"),
    ]

    private static let categorySeeds: [CategorySeed] = [
        // Expense
        CategorySeed(id: "5EED0000-0000-4000-8000-00000000E001", name: "Ăn uống",
                     icon: "fork.knife", colorHex: "FF9500", kind: .expense, sortOrder: 0),
        CategorySeed(id: "5EED0000-0000-4000-8000-00000000E002", name: "Ăn nhậu",
                     icon: "wineglass.fill", colorHex: "AF52DE", kind: .expense, sortOrder: 1),
        CategorySeed(id: "5EED0000-0000-4000-8000-00000000E003", name: "Đi chơi",
                     icon: "ticket.fill", colorHex: "FF2D55", kind: .expense, sortOrder: 2),
        CategorySeed(id: "5EED0000-0000-4000-8000-00000000E004", name: "Công cụ & phần mềm",
                     icon: "wrench.and.screwdriver.fill", colorHex: "5E5CE6", kind: .expense, sortOrder: 3),
        CategorySeed(id: "5EED0000-0000-4000-8000-00000000E005", name: "Di chuyển",
                     icon: "car.fill", colorHex: "0A84FF", kind: .expense, sortOrder: 4),
        CategorySeed(id: "5EED0000-0000-4000-8000-00000000E006", name: "Nhà cửa",
                     icon: "house.fill", colorHex: "30B0C7", kind: .expense, sortOrder: 5),
        CategorySeed(id: "5EED0000-0000-4000-8000-00000000E007", name: "Mua sắm",
                     icon: "bag.fill", colorHex: "FF375F", kind: .expense, sortOrder: 6),
        CategorySeed(id: "5EED0000-0000-4000-8000-00000000E008", name: "Sức khoẻ",
                     icon: "heart.fill", colorHex: "FF3B30", kind: .expense, sortOrder: 7),
        CategorySeed(id: "5EED0000-0000-4000-8000-00000000E009", name: "Hoá đơn",
                     icon: "doc.text.fill", colorHex: "FF9F0A", kind: .expense, sortOrder: 8),
        CategorySeed(id: "5EED0000-0000-4000-8000-00000000E010", name: "Quảng cáo",
                     icon: "megaphone.fill", colorHex: "FF6482", kind: .expense, sortOrder: 9),
        CategorySeed(id: "5EED0000-0000-4000-8000-00000000E011", name: "Thuê mặt bằng",
                     icon: "storefront.fill", colorHex: "64D2FF", kind: .expense, sortOrder: 10),
        CategorySeed(id: "5EED0000-0000-4000-8000-00000000E012", name: "Điện nước internet",
                     icon: "bolt.fill", colorHex: "FFD60A", kind: .expense, sortOrder: 11),
        CategorySeed(id: "5EED0000-0000-4000-8000-00000000E013", name: "Nhân công",
                     icon: "person.2.fill", colorHex: "98989D", kind: .expense, sortOrder: 12),
        CategorySeed(id: "5EED0000-0000-4000-8000-00000000E014", name: "Lãi vay & phí",
                     icon: "percent", colorHex: "BF5AF2", kind: .expense, sortOrder: 13),
        CategorySeed(id: "5EED0000-0000-4000-8000-00000000E015", name: "Chi khác",
                     icon: "ellipsis.circle.fill", colorHex: "8E8E93", kind: .expense, sortOrder: 14),
        // Income
        CategorySeed(id: "5EED0000-0000-4000-8000-000000001001", name: "Doanh thu dịch vụ",
                     icon: "briefcase.fill", colorHex: "30D158", kind: .income, sortOrder: 0),
        CategorySeed(id: "5EED0000-0000-4000-8000-000000001002", name: "Tiền thuê phòng",
                     icon: "bed.double.fill", colorHex: "32ADE6", kind: .income, sortOrder: 1),
        CategorySeed(id: "5EED0000-0000-4000-8000-000000001003", name: "Lương & thù lao",
                     icon: "banknote", colorHex: "34C759", kind: .income, sortOrder: 2),
        CategorySeed(id: "5EED0000-0000-4000-8000-000000001004", name: "Lãi tiết kiệm",
                     icon: "chart.line.uptrend.xyaxis", colorHex: "00C7BE", kind: .income, sortOrder: 3),
        CategorySeed(id: "5EED0000-0000-4000-8000-000000001005", name: "Hoàn tiền",
                     icon: "arrow.uturn.backward.circle.fill", colorHex: "30B0C7", kind: .income, sortOrder: 4),
        CategorySeed(id: "5EED0000-0000-4000-8000-000000001006", name: "Thu khác",
                     icon: "tray.and.arrow.down.fill", colorHex: "98989D", kind: .income, sortOrder: 5),
    ]
}
