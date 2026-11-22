import XCTest

/// End-to-end smoke tests for AM Finance. Every test launches the app fresh
/// with `-uiTestInMemoryStore` — a throwaway, seeded in-memory SwiftData
/// store — so real user data is never touched.
///
/// The suite is grouped into five launches instead of one per flow — each
/// launch costs ~10-15 s of simulator + app idle time, so steps that can share
/// a store run together. Covers: the four tabs, quick-add (expense and
/// income), edit/delete, settings screens, accounts/cards/loans, debts,
/// reports, the second-pass feature wiring (wallet link/sync, budgets,
/// recurring, reminders, app lock, business hub, receivables, balance
/// trend) and the third-pass features (room rentals, CSV import, the
/// rent-collection and bank-transaction reminder switches). Vietnamese
/// UI, VND amounts ("150.000 ₫").
///
/// Reliability rules used throughout:
/// - wait for `exists AND hittable` before tapping anything that may sit
///   under a dismissing sheet or a still-presenting screen;
/// - scroll (`reveal`) BEFORE waiting for off-screen elements — never burn a
///   full existence timeout on a row that only needs one swipe;
/// - for dialogs, wait for the dialog's own title and tap the button inside
///   the sheet that contains it — the editor has an identical row and a tap
///   through the scrim would dismiss the dialog without confirming.
@MainActor
final class AMFinanceUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTestInMemoryStore"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - 1. Tabs, reports and settings

    func testTabsReportsAndSettings() throws {
        // Dashboard: the net-worth card renders.
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 20), "tab bar missing")
        XCTAssertTrue(
            app.staticTexts["Tài sản ròng"].waitForExistence(timeout: 8),
            "dashboard net-worth card missing")

        openTab("Giao dịch")
        XCTAssertTrue(
            app.buttons["Tháng trước"].waitForExistence(timeout: 5),
            "transactions month switcher missing")

        openTab("Nợ & Thẻ")
        XCTAssertTrue(
            app.staticTexts["Chưa có thẻ hay khoản vay"]
                .waitForExistence(timeout: 5)
                || app.staticTexts["Tổng dư nợ"].exists,
            "debts screen shows neither empty state nor totals")

        // Reports: period switcher and the scope menu.
        openTab("Báo cáo")
        let period = app.segmentedControls.firstMatch
        XCTAssertTrue(period.waitForExistence(timeout: 8),
                      "report period picker missing")
        for segment in ["Quý", "Năm", "Tháng"] {
            period.buttons[segment].tap()
            XCTAssertTrue(
                app.navigationBars.staticTexts["Báo cáo"].exists,
                "reports screen lost after switching to \(segment)")
        }

        // Scope menu: Tất cả → Cá nhân → Làm web → Tất cả.
        let scope = app.buttons["Phạm vi báo cáo"]
        XCTAssertTrue(scope.waitForExistence(timeout: 5), "scope menu missing")
        for choice in ["Cá nhân", "Làm web", "Tất cả"] {
            scope.tap()
            tapOption(choice)
            XCTAssertTrue(
                app.navigationBars.staticTexts["Báo cáo"].exists,
                "reports screen lost after scope \(choice)")
        }

        // Settings from the dashboard gear.
        openTab("Tổng quan")
        let gear = app.buttons["Cài đặt"]
        XCTAssertTrue(waitReady(gear, timeout: 8), "settings gear missing")
        gear.tap()
        XCTAssertTrue(
            app.navigationBars.staticTexts["Cài đặt"].waitForExistence(timeout: 5),
            "settings screen missing")

        // Danh mục → add a category.
        tapOption("Danh mục")
        XCTAssertTrue(
            app.navigationBars.staticTexts["Danh mục"].waitForExistence(timeout: 5),
            "categories screen missing")
        tapWhenReady(app.buttons["Thêm danh mục"], "add-category button missing")
        let nameField = app.textFields["Tên danh mục"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5),
                      "category name field missing")
        nameField.tap()
        nameField.typeText("Cafe sáng")
        tapWhenReady(app.buttons["Thêm"], "category save button missing")
        assertVisible(app.staticTexts["Cafe sáng"],
                      "new category did not appear")
        goBack(to: "Cài đặt")

        // Mảng kinh doanh opens.
        tapOption("Mảng kinh doanh")
        XCTAssertTrue(
            app.navigationBars.staticTexts["Mảng kinh doanh"]
                .waitForExistence(timeout: 5),
            "businesses screen missing")
        goBack(to: "Cài đặt")

        // Sao lưu & khôi phục opens.
        tapOption("Sao lưu & khôi phục")
        XCTAssertTrue(
            app.navigationBars.staticTexts["Sao lưu & Khôi phục"]
                .waitForExistence(timeout: 5),
            "backup screen missing")
        goBack(to: "Cài đặt")
        goBack(to: "Tổng quan")
    }

    // MARK: - 2. Transactions: quick-add, income + business, edit, delete

    func testTransactionsAddEditDelete() throws {
        // Quick-add an expense; it lands back on the dashboard.
        quickAddExpense(amount: 150_000, category: "Ăn nhậu")

        // Quick-add an income tagged to a business.
        tapQuickAdd()
        let incomeSegment = app.buttons["Thu"]
        XCTAssertTrue(incomeSegment.waitForExistence(timeout: 4),
                      "income segment missing")
        incomeSegment.tap()
        typeAmount(5_000_000)
        pickCategory("Doanh thu dịch vụ")
        pickBusiness("Làm web")
        saveSheet()

        // Dashboard: this month's expense, the business P&L and the recent
        // list — checked top-down so one scroll direction covers all cards.
        let monthCard = scopedElement("dashboard.monthCard")
        assertVisible(monthCard, "month card missing")
        XCTAssertTrue(monthCard.staticTexts["-150.000 ₫"].exists,
                      "month expense does not show 150.000")

        let businessName = scopedElement("dashboard.businessCard")
            .staticTexts["Làm web"]
        assertVisible(businessName, "P&L card does not show business 'Làm web'")

        let recentItem = scopedElement("dashboard.recentCard")
            .staticTexts["Ăn nhậu"]
        assertVisible(recentItem, "recent-transactions card does not show Ăn nhậu")

        // The expense row is also in "Giao dịch".
        openTab("Giao dịch")
        XCTAssertTrue(
            app.staticTexts["Ăn nhậu"].waitForExistence(timeout: 5),
            "transaction row missing in list")
        XCTAssertTrue(app.staticTexts["-150.000 ₫"].exists,
                      "expense amount missing in list")

        // Two more expenses to edit and delete.
        quickAddExpense(amount: 100_000, category: "Ăn uống")
        quickAddExpense(amount: 50_000, category: "Di chuyển")

        // Open "Ăn uống", change the amount, save. The keypad's long-press
        // "clear" is unreliable under synthesized touches (the key's Button
        // tap action can win over the simultaneous long-press gesture and
        // only delete one digit), so edit incrementally instead: backspace
        // once, append one digit → 100000 → 10000 → 100002.
        tapTransactionRow("Ăn uống")
        XCTAssertTrue(
            app.navigationBars.staticTexts["Sửa giao dịch"]
                .waitForExistence(timeout: 5),
            "editor did not open")
        revealEditorKeypad()
        let backspace = app.buttons["Xoá"]
        XCTAssertTrue(backspace.waitForExistence(timeout: 4),
                      "backspace key missing")
        backspace.tap()
        app.buttons["2"].tap()
        saveSheet()

        XCTAssertTrue(
            app.staticTexts["-100.002 ₫"].waitForExistence(timeout: 5),
            "edited amount missing")
        XCTAssertFalse(app.staticTexts["-100.000 ₫"].exists,
                       "old amount still shown")

        // Delete "Di chuyển" from inside the editor.
        tapTransactionRow("Di chuyển")
        XCTAssertTrue(
            app.navigationBars.staticTexts["Sửa giao dịch"]
                .waitForExistence(timeout: 5),
            "editor did not open for delete")
        let deleteRow = app.buttons["Xoá giao dịch"]
        if !reveal(deleteRow, maxSwipes: 6) {
            XCTAssertTrue(
                deleteRow.waitForExistence(timeout: 3),
                "delete button missing in editor")
        }
        deleteRow.tap()
        confirmDestructive(label: "Xoá giao dịch",
                           dialogTitle: "Xoá giao dịch này?")
        waitForDisappearance(app.staticTexts["Di chuyển"],
                             message: "deleted row still visible")

        // Settings → Xoá dữ liệu → level A wipes the remaining rows,
        // rebuilds the root onto "Tổng quan", leaves "Giao dịch" on its
        // empty state and still opens an account detail without crashing.
        openTab("Tổng quan")
        let settingsGear = app.buttons["Cài đặt"]
        XCTAssertTrue(waitReady(settingsGear, timeout: 8),
                      "settings gear missing")
        settingsGear.tap()
        XCTAssertTrue(
            app.navigationBars.staticTexts["Cài đặt"]
                .waitForExistence(timeout: 5),
            "settings screen missing")
        tapOption("Xoá dữ liệu")
        XCTAssertTrue(
            app.navigationBars.staticTexts["Xoá dữ liệu"]
                .waitForExistence(timeout: 5),
            "data reset screen missing")
        tapOption("Xoá toàn bộ giao dịch")

        // First confirmation step — the dialog button carries the count.
        confirmDestructive(label: "Xoá 3 giao dịch",
                           dialogTitle: "Xoá dữ liệu?")

        // Second step — the destructive button only enables after
        // typing XOA into the alert's field.
        let typeField = app.alerts.textFields.firstMatch
        XCTAssertTrue(typeField.waitForExistence(timeout: 5),
                      "typed-confirmation field missing")
        typeField.tap()
        typeField.typeText("XOA")
        tapWhenReady(app.alerts.buttons["Xoá"],
                     "typed-confirmation delete button missing")
        // Success notice — dismissing it rebuilds the root view.
        XCTAssertTrue(
            app.alerts["Đã xoá dữ liệu"].waitForExistence(timeout: 8),
            "reset success alert missing")
        tapWhenReady(app.alerts.buttons["OK"], "success OK missing")

        XCTAssertTrue(
            app.staticTexts["Tài sản ròng"].waitForExistence(timeout: 10),
            "dashboard did not come back after reset")
        openTab("Giao dịch")
        XCTAssertTrue(
            app.staticTexts["Chưa có giao dịch"].waitForExistence(timeout: 5),
            "transactions empty state missing after reset")

        // The seeded cash account's detail must still open — no screen
        // may hold a reference to a deleted object.
        openTab("Tổng quan")
        let netWorthAfter = scopedElement("dashboard.netWorthCard")
        XCTAssertTrue(netWorthAfter.waitForExistence(timeout: 8),
                      "net-worth card missing after reset")
        netWorthAfter.tap()
        XCTAssertTrue(
            app.navigationBars.staticTexts["Tài khoản"]
                .waitForExistence(timeout: 5),
            "accounts screen missing after reset")
        tapRowAny("Tiền mặt")
        XCTAssertTrue(
            app.navigationBars.staticTexts["Tiền mặt"]
                .waitForExistence(timeout: 5),
            "account detail missing after reset")
        goBack(to: "Tài khoản")
        goBack(to: "Tổng quan")
    }

    // MARK: - 3. Accounts, cards, loans, debts

    func testAccountsAndDebts() throws {
        // Net worth card → accounts list.
        let netWorth = scopedElement("dashboard.netWorthCard")
        XCTAssertTrue(netWorth.waitForExistence(timeout: 15),
                      "net-worth card missing")
        netWorth.tap()
        XCTAssertTrue(
            app.navigationBars.staticTexts["Tài khoản"].waitForExistence(timeout: 5),
            "accounts screen missing")

        addAccount(
            name: "Ngân hàng ACB",
            kind: "Ngân hàng",
            openingBalance: 5_000_000)

        addCreditCard(
            name: "Thẻ Visa",
            debt: 2_000_000,
            creditLimit: "50000000",
            statementDayIncrements: 1)  // 15 → 16; grace stays at 15 days

        addLoan(
            name: "Vay mua xe",
            debt: 3_000_000,
            principal: "3000000",
            rate: "12",
            termMonths: "6",   // short schedule keeps detail render fast
            paymentDayIncrements: 1)  // 1 → 2

        // Open each account detail screen; the card's statement screen is
        // checked while its detail is already open.
        for name in ["Ngân hàng ACB", "Thẻ Visa", "Vay mua xe"] {
            tapRowAny(name)
            XCTAssertTrue(
                app.navigationBars.staticTexts[name].waitForExistence(timeout: 5),
                "detail for \(name) missing")
            if name == "Thẻ Visa" {
                tapOption("Sao kê & thanh toán thẻ")
                assertVisible(app.staticTexts["Sao kê gần nhất"],
                              "card statement section missing")
                goBack(to: "Thẻ Visa")
            }
            goBack(to: "Tài khoản")
        }

        // Nợ & Thẻ: card and loan are listed.
        openTab("Nợ & Thẻ")
        XCTAssertTrue(app.staticTexts["Tổng dư nợ"].waitForExistence(timeout: 8),
                      "debts totals missing")
        XCTAssertTrue(app.staticTexts["Thẻ Visa"].exists, "card not listed")
        XCTAssertTrue(app.staticTexts["Vay mua xe"].exists, "loan not listed")

        // Card detail → record a payment from the bank account.
        tapRowAny("Thẻ Visa")
        let payButton = app.buttons.matching(
            NSPredicate(format: "label == %@", "Trả nợ thẻ")).firstMatch
        XCTAssertTrue(payButton.waitForExistence(timeout: 5),
                      "card payment button missing")
        payButton.tap()
        XCTAssertTrue(
            app.navigationBars.staticTexts["Trả nợ thẻ"].waitForExistence(timeout: 5),
            "card payment sheet missing")
        tapPickerRow("Trả từ")
        tapOption("Ngân hàng ACB")
        saveSheet()

        // The payment transfer is recorded on the card.
        let paymentRow = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@", "Trả nợ thẻ Thẻ Visa"))
            .firstMatch
        assertVisible(paymentRow, "payment row missing on card detail")
        goBack(to: "Nợ & Thẻ")

        // Loan detail → repayment schedule is visible.
        tapRowAny("Vay mua xe")
        assertVisible(app.staticTexts["Lịch trả nợ"], "loan schedule missing")
        goBack(to: "Nợ & Thẻ")

        // The payment shows up as a transfer in the transactions list.
        openTab("Giao dịch")
        let transferRow = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@", "Trả nợ thẻ Thẻ Visa"))
            .firstMatch
        assertVisible(transferRow, "card payment missing in transactions")
    }

    // MARK: - 4. Second-pass feature wiring

    /// Every screen wired in the second integration pass: the wallet
    /// bank/link rows, budgets, recurring, reminders, app lock, the
    /// business hub, client receivables and the balance-trend entry
    /// points. One launch — the seeded in-memory store never signs in,
    /// so wallet screens are checked in their signed-out/empty states.
    func testWiredFeatureScreens() throws {
        // An income tagged to a business: gives the dashboard a business
        // P&L card and any transaction at all (the month card, the budget
        // card and the business card hide behind the welcome state
        // otherwise).
        tapQuickAdd()
        let incomeSegment = app.buttons["Thu"]
        XCTAssertTrue(incomeSegment.waitForExistence(timeout: 4),
                      "income segment missing")
        incomeSegment.tap()
        typeAmount(5_000_000)
        pickCategory("Doanh thu dịch vụ")
        pickBusiness("Làm web")
        saveSheet()

        // A credit card — the receivable advance is paid from it.
        let netWorth = scopedElement("dashboard.netWorthCard")
        XCTAssertTrue(netWorth.waitForExistence(timeout: 15),
                      "net-worth card missing")
        netWorth.tap()
        XCTAssertTrue(
            app.navigationBars.staticTexts["Tài khoản"]
                .waitForExistence(timeout: 5),
            "accounts screen missing")
        addCreditCard(
            name: "Thẻ Visa", debt: 1_000_000,
            creditLimit: "30000000", statementDayIncrements: 0)

        // Seeded cash account → the new "Số dư" section rows.
        tapRowAny("Tiền mặt")
        XCTAssertTrue(
            app.navigationBars.staticTexts["Tiền mặt"]
                .waitForExistence(timeout: 5),
            "cash detail missing")
        tapOption("Lịch sử số dư")
        XCTAssertTrue(
            app.navigationBars.staticTexts["Số dư"]
                .waitForExistence(timeout: 5),
            "balance-trend screen missing")
        goBack(to: "Tiền mặt")
        tapOption("Đặt số dư thực tế")
        XCTAssertTrue(
            app.navigationBars.staticTexts["Đặt số dư thực tế"]
                .waitForExistence(timeout: 5),
            "anchor sheet missing")
        let cancel = app.buttons["Huỷ"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 4), "sheet cancel missing")
        cancel.tap()
        goBack(to: "Tài khoản")
        goBack(to: "Tổng quan")

        // Settings → the new rows, top to bottom.
        let gear = app.buttons["Cài đặt"]
        XCTAssertTrue(waitReady(gear, timeout: 8), "settings gear missing")
        gear.tap()
        XCTAssertTrue(
            app.navigationBars.staticTexts["Cài đặt"]
                .waitForExistence(timeout: 5),
            "settings screen missing")

        // Wallet connection — signed out, so only the sign-in button and
        // the unconfigured status show.
        tapOption("Kết nối wallet.amx.vn")
        XCTAssertTrue(
            app.navigationBars.staticTexts["Kết nối ví AMX"]
                .waitForExistence(timeout: 5),
            "wallet link screen missing")
        XCTAssertTrue(
            app.buttons["Đăng nhập AMX"].waitForExistence(timeout: 5),
            "wallet link is not in the signed-out state")
        goBack(to: "Cài đặt")

        tapOption("Tài khoản liên kết & đồng bộ")
        XCTAssertTrue(
            app.navigationBars.staticTexts["Đồng bộ ngân hàng"]
                .waitForExistence(timeout: 5),
            "sync accounts screen missing")
        goBack(to: "Cài đặt")

        // Inbox — nothing imported, so the empty state shows.
        tapOption("Giao dịch chờ phân loại")
        XCTAssertTrue(
            app.navigationBars.staticTexts["Chờ phân loại"]
                .waitForExistence(timeout: 5),
            "inbox screen missing")
        assertVisible(app.staticTexts["Không còn gì chờ"],
                      "inbox empty state missing")
        goBack(to: "Cài đặt")

        tapOption("Quy tắc tự phân loại")
        XCTAssertTrue(
            app.navigationBars.staticTexts["Quy tắc tự động"]
                .waitForExistence(timeout: 5),
            "rules screen missing")
        assertVisible(app.staticTexts["Chưa có quy tắc"],
                      "rules empty state missing")
        goBack(to: "Cài đặt")

        // Budgets — create the overall monthly budget; it must land back
        // on the dashboard card.
        tapOption("Ngân sách")
        XCTAssertTrue(
            app.navigationBars.staticTexts["Ngân sách"]
                .waitForExistence(timeout: 5),
            "budgets screen missing")
        // Two buttons share this label — the toolbar plus and the empty
        // state's action — so tap the first hittable one.
        tapOption("Thêm ngân sách")
        XCTAssertTrue(
            app.navigationBars.staticTexts["Ngân sách mới"]
                .waitForExistence(timeout: 5),
            "budget sheet missing")
        typeAmount(5_000_000)
        tapWhenReady(app.buttons["Thêm"], "budget save button missing")
        assertVisible(app.staticTexts["Ngân sách chi tiêu cá nhân"],
                      "newly created budget row missing")
        goBack(to: "Cài đặt")

        // Recurring — one monthly rule (frequency defaults to monthly),
        // confirmed in the list.
        tapOption("Giao dịch định kỳ")
        XCTAssertTrue(
            app.navigationBars.staticTexts["Giao dịch lặp lại"]
                .waitForExistence(timeout: 5),
            "recurring screen missing")
        tapWhenReady(app.buttons["Thêm quy tắc lặp lại"],
                     "add-recurring button missing")
        XCTAssertTrue(
            app.navigationBars.staticTexts["Quy tắc lặp lại mới"]
                .waitForExistence(timeout: 5),
            "recurring sheet missing")
        fillField(app.textFields["Ví dụ: Tiền thuê phòng"], with: "Tiền thuê")
        typeAmount(7_000_000)
        saveSheet()
        assertVisible(app.staticTexts["Tiền thuê"],
                      "newly created recurring rule missing")
        goBack(to: "Cài đặt")

        // Reminders — the screen opens; the toggle must stay off so no
        // permission prompt ever appears.
        tapOption("Nhắc nhở")
        XCTAssertTrue(
            app.navigationBars.staticTexts["Nhắc nhở"]
                .waitForExistence(timeout: 5),
            "reminders screen missing")
        assertVisible(app.switches["Bật nhắc nhở"],
                      "reminders master toggle missing")
        goBack(to: "Cài đặt")

        // Business hub → one business detail.
        tapOption("Lãi lỗ theo mảng")
        XCTAssertTrue(
            app.navigationBars.staticTexts["Mảng kinh doanh"]
                .waitForExistence(timeout: 5),
            "business hub missing")
        tapRowAny("Làm web")
        XCTAssertTrue(
            app.navigationBars.staticTexts["Làm web"]
                .waitForExistence(timeout: 5),
            "business detail missing")
        goBack(to: "Mảng kinh doanh")
        goBack(to: "Cài đặt")

        // Client receivable: create "Khách A", advance 2.000.000 ₫ paid
        // by the credit card, then read the outstanding amount.
        tapOption("Khoản ứng hộ khách")
        XCTAssertTrue(
            app.navigationBars.staticTexts["Khoản ứng hộ khách"]
                .waitForExistence(timeout: 5),
            "receivables screen missing")
        // The toolbar plus and the empty-state action share this label —
        // tap the first hittable one.
        tapOption("Thêm khách hàng")
        XCTAssertTrue(
            app.navigationBars.staticTexts["Khách hàng mới"]
                .waitForExistence(timeout: 5),
            "client sheet missing")
        fillField(app.textFields["Tên khách hàng"], with: "Khách A")
        tapWhenReady(app.buttons["Thêm"], "client save button missing")
        // A fresh client owes nothing, so it sits inside the collapsed
        // "Đã tất toán" group — expand it before the row exists.
        tapRowAny("Đã tất toán")
        tapRowAny("Khách A")
        XCTAssertTrue(
            app.navigationBars.staticTexts["Khách A"]
                .waitForExistence(timeout: 5),
            "receivable detail missing")
        tapOption("Ứng tiền cho khách")
        XCTAssertTrue(
            app.navigationBars.staticTexts["Ứng tiền cho khách"]
                .waitForExistence(timeout: 5),
            "advance sheet missing")
        typeAmount(2_000_000)
        tapPickerRow("Trả từ")
        tapRowAny("Thẻ Visa")
        saveSheet()
        assertVisible(app.staticTexts["Khách đang nợ"],
                      "receivable outstanding header missing")
        // AmountText signs a positive outstanding with a leading "+".
        assertVisible(app.staticTexts["+2.000.000 ₫"],
                      "outstanding amount does not show +2.000.000 ₫")
        goBack(to: "Khoản ứng hộ khách")
        goBack(to: "Cài đặt")

        // App lock — the settings screen opens (lock itself stays off).
        tapOption("Khoá ứng dụng")
        XCTAssertTrue(
            app.navigationBars.staticTexts["Khoá ứng dụng"]
                .waitForExistence(timeout: 5),
            "app lock screen missing")
        assertVisible(app.staticTexts["Khoá bằng Face ID"],
                      "app lock toggle missing")
        goBack(to: "Cài đặt")
        goBack(to: "Tổng quan")

        // Dashboard, top-down: the new budget card, then the business
        // card's header link and row link.
        assertVisible(app.staticTexts["Ngân sách chi tiêu cá nhân"],
                      "dashboard budget card missing")

        let businessCard = scopedElement("dashboard.businessCard")
        XCTAssertTrue(businessCard.waitForExistence(timeout: 5),
                      "business card missing")
        // Card links surface as buttons whose combined label starts with
        // the row title — the inner text alone is not always hittable.
        let hubLink = hittableOrRevealedInOuter(businessCard
            .descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Kinh doanh")))
        XCTAssertNotNil(hubLink, "business card header missing")
        hubLink?.tap()
        XCTAssertTrue(
            app.navigationBars.staticTexts["Mảng kinh doanh"]
                .waitForExistence(timeout: 5),
            "business card header did not push the hub")
        goBack(to: "Tổng quan")

        let businessRow = hittableOrRevealedInOuter(scopedElement("dashboard.businessCard")
            .descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Làm web")))
        XCTAssertNotNil(businessRow, "business card row missing")
        businessRow?.tap()
        XCTAssertTrue(
            app.navigationBars.staticTexts["Làm web"]
                .waitForExistence(timeout: 5),
            "business card row did not push the detail")
        goBack(to: "Tổng quan")
    }

    // MARK: - 5. Rentals, CSV import and the new reminder switches

    /// Third-pass wiring end to end: the two new reminder switches, then
    /// a serviced-apartment room, a lease, this month's rent collected
    /// into the seeded cash account — the room flips to "Đã thu" and the
    /// income lands on the dashboard's "Căn hộ dịch vụ" P&L row, whose
    /// business detail is the second entry point to the room board —
    /// and finally the CSV import's first step. Settings rows are
    /// visited top-down because the reveal helpers only scroll up.
    func testRentalsImportAndReminders() throws {
        // Settings → Kế hoạch → Nhắc nhở: the rent-collection and
        // bank-transaction switches exist; both stay off so no
        // permission prompt ever appears.
        let gear = app.buttons["Cài đặt"]
        XCTAssertTrue(waitReady(gear, timeout: 15), "settings gear missing")
        gear.tap()
        XCTAssertTrue(
            app.navigationBars.staticTexts["Cài đặt"]
                .waitForExistence(timeout: 5),
            "settings screen missing")

        tapOption("Nhắc nhở")
        XCTAssertTrue(
            app.navigationBars.staticTexts["Nhắc nhở"]
                .waitForExistence(timeout: 5),
            "reminders screen missing")
        assertVisible(app.switches["Thu tiền phòng"],
                      "rent-collection switch missing")
        assertVisible(app.switches["Thông báo giao dịch ngân hàng mới"],
                      "bank-transaction switch missing")
        goBack(to: "Cài đặt")

        // Phân loại → Phòng cho thuê.
        tapOption("Phòng cho thuê")
        XCTAssertTrue(
            app.navigationBars.staticTexts["Phòng cho thuê"]
                .waitForExistence(timeout: 5),
            "rentals screen missing")

        // A room under the serviced-apartment business at 5.000.000 ₫ —
        // the toolbar "+" and the empty-state action share the "Thêm
        // phòng" label, so the first hittable one wins.
        tapOption("Thêm phòng")
        XCTAssertTrue(
            app.navigationBars.staticTexts["Phòng mới"]
                .waitForExistence(timeout: 5),
            "room sheet missing")
        fillField(app.textFields["Tên phòng"], with: "Phòng 101")
        // A "Mảng kinh doanh" row sits on the settings screen behind the
        // sheet — only the frontmost hittable match may be tapped.
        tapFrontPickerRow("Mảng kinh doanh")
        tapOption("Căn hộ dịch vụ")
        tapPickerRow("Giá niêm yết")
        ensureKeypadVisible()
        // The "000" key sits on the keypad's bottom row — reveal it too.
        _ = reveal(app.buttons["000"], maxSwipes: 4)
        typeAmount(5_000_000)
        tapWhenReady(app.buttons["Thêm"], "room save button missing")
        let newRoom = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Phòng 101"))
            .firstMatch
        assertVisible(newRoom, "new room row missing")

        // Room detail → lease for a tenant; the rent defaults to the list
        // price and the start date to today, so it covers this month.
        tapRowAny("Phòng 101")
        XCTAssertTrue(
            app.navigationBars.staticTexts["Phòng 101"]
                .waitForExistence(timeout: 5),
            "room detail missing")
        tapOption("Hợp đồng mới")
        XCTAssertTrue(
            app.navigationBars.staticTexts["Hợp đồng mới"]
                .waitForExistence(timeout: 5),
            "lease sheet missing")
        fillField(app.textFields["Tên người thuê"], with: "Nguyễn Văn A")
        tapWhenReady(app.buttons["Thêm"], "lease save button missing")
        let tenantRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Nguyễn Văn A"))
            .firstMatch
        assertVisible(tenantRow, "tenant missing on room detail")

        // Collect this month — the sheet pre-fills the outstanding rent
        // and defaults the receiver to the only payable account, "Tiền
        // mặt", so saving as-is records the rent into cash.
        let collect = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", "Thu tiền tháng"))
            .firstMatch
        if !reveal(collect, maxSwipes: 6) {
            XCTAssertTrue(collect.waitForExistence(timeout: 3),
                          "collect-rent action missing")
        }
        collect.tap()
        XCTAssertTrue(
            app.navigationBars.staticTexts["Thu tiền Phòng 101"]
                .waitForExistence(timeout: 5),
            "collect sheet missing")
        saveSheet()

        // The payment lands in the room's history, and the board row
        // flips to "Đã thu" — scoped to the list because the month
        // header's totals cell shares the word.
        let historyRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "Tiền Phòng 101 tháng"))
            .firstMatch
        assertVisible(historyRow, "rent payment missing in room history")
        goBack(to: "Phòng cho thuê")
        XCTAssertTrue(paidRoomTagExists(),
                      "room row not marked 'Đã thu'")
        goBack(to: "Cài đặt")

        // CSV import — the first step renders (file row, target-account
        // picker); the system file picker is not driven.
        tapOption("Nhập sao kê CSV")
        XCTAssertTrue(
            app.navigationBars.staticTexts["Nhập sao kê CSV"]
                .waitForExistence(timeout: 5),
            "csv import screen missing")
        assertVisible(app.buttons["Chọn tệp CSV…"],
                      "csv file row missing")
        let accountRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "Tài khoản nhận"))
            .firstMatch
        assertVisible(accountRow, "csv account picker missing")
        goBack(to: "Cài đặt")
        goBack(to: "Tổng quan")

        // Dashboard: the collected rent lands on the serviced-apartment
        // P&L row, and the row pushes the business detail whose own
        // "Phòng cho thuê" entry reaches the same board.
        let card = hittableOrRevealedInOuter(
            app.descendants(matching: .any)
                .matching(identifier: "dashboard.businessCard"))
        XCTAssertNotNil(card, "business card missing")
        let businessCard = scopedElement("dashboard.businessCard")
        XCTAssertTrue(
            businessCard.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS %@", "Căn hộ dịch vụ"))
                .firstMatch.exists,
            "P&L card does not show 'Căn hộ dịch vụ'")
        XCTAssertTrue(
            businessCard.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS %@", "Thu 5 tr"))
                .firstMatch.exists,
            "P&L row does not show the 5.000.000 ₫ rent income")

        let apartmentRow = hittableOrRevealedInOuter(businessCard
            .descendants(matching: .any)
            .matching(NSPredicate(
                format: "label BEGINSWITH %@", "Căn hộ dịch vụ")))
        XCTAssertNotNil(apartmentRow, "P&L row for 'Căn hộ dịch vụ' missing")
        apartmentRow?.tap()
        XCTAssertTrue(
            app.navigationBars.staticTexts["Căn hộ dịch vụ"]
                .waitForExistence(timeout: 5),
            "business detail missing")
        let roomsLink = hittableOrRevealedInOuter(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@", "Đang thuê")))
        XCTAssertNotNil(roomsLink, "business-detail rentals row missing")
        roomsLink?.tap()
        XCTAssertTrue(
            app.navigationBars.staticTexts["Phòng — Căn hộ dịch vụ"]
                .waitForExistence(timeout: 5),
            "scoped rentals screen missing")
        XCTAssertTrue(paidRoomTagExists(),
                      "scoped board does not show 'Đã thu'")
        goBack(to: "Căn hộ dịch vụ")
        goBack(to: "Tổng quan")
    }

    // MARK: - Flow helpers

    /// Taps the floating "+" (identifier `root.quickAdd`) and waits for the
    /// editor sheet. Waits for hittable, not just exists — the button is in
    /// the tree even while a previous sheet is still dismissing.
    private func tapQuickAdd() {
        let button = app.buttons["root.quickAdd"]
        XCTAssertTrue(waitReady(button, timeout: 15),
                      "quick-add button missing")
        button.tap()
        XCTAssertTrue(
            app.navigationBars.staticTexts["Giao dịch mới"]
                .waitForExistence(timeout: 5),
            "transaction editor did not open")
    }

    /// Adds an expense through the quick-add sheet.
    private func quickAddExpense(amount: Int64, category: String) {
        tapQuickAdd()
        typeAmount(amount)
        pickCategory(category)
        saveSheet()
    }

    /// Types an amount on the đồng keypad — trailing "000" groups go through
    /// the dedicated key so large numbers take few taps. Waits once for the
    /// keypad, then taps without re-resolving: keys do not move.
    private func typeAmount(_ amount: Int64) {
        XCTAssertTrue(app.buttons["1"].waitForExistence(timeout: 4),
                      "amount keypad missing")
        var digits = String(amount)
        var triples = 0
        while digits.hasSuffix("000") {
            digits.removeLast(3)
            triples += 1
        }
        for character in digits {
            app.buttons[String(character)].tap()
        }
        for _ in 0..<triples {
            app.buttons["000"].tap()
        }
    }

    /// In edit mode the keypad is hidden — reveal it through the amount
    /// toggle and prove it opened before typing.
    private func revealEditorKeypad() {
        let toggle = app.buttons["Số tiền"]
        XCTAssertTrue(waitReady(toggle, timeout: 4), "amount toggle missing")
        toggle.tap()
        XCTAssertTrue(app.buttons["1"].waitForExistence(timeout: 4),
                      "keypad did not open")
    }

    /// Scrolls inside the editor form until the category cell exists, then
    /// taps it.
    private func pickCategory(_ name: String) {
        let cell = app.buttons["txEditor.category.\(name)"]
        if !reveal(cell, maxSwipes: 6) {
            XCTAssertTrue(cell.waitForExistence(timeout: 3),
                          "category \(name) not found")
        }
        cell.tap()
    }

    /// Picks a business in the editor's "Kinh doanh" navigation-link picker.
    private func pickBusiness(_ name: String) {
        tapPickerRow("Kinh doanh")
        tapOption(name)
    }

    /// Taps a "Picker.navigationLink" form row whose combined label starts
    /// with `title` ("Loại tài khoản, …", "Kinh doanh, …", "Trả từ"), then
    /// waits for the pushed option list.
    private func tapPickerRow(_ title: String) {
        var row = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        if !reveal(row, maxSwipes: 4) {
            row = app.staticTexts.matching(
                NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
            _ = reveal(row, maxSwipes: 4)
        }
        XCTAssertTrue(row.waitForExistence(timeout: 3),
                      "picker '\(title)' missing")
        row.tap()
    }

    /// True when a room row carries the "Đã thu" status tag — the board's
    /// month header uses the same word in its totals, so the check is
    /// scoped to whichever list container type is on screen.
    private func paidRoomTagExists() -> Bool {
        for query in [app.collectionViews, app.scrollViews] {
            if query.descendants(matching: .staticText)
                .matching(NSPredicate(format: "label == %@", "Đã thu"))
                .firstMatch.exists {
                return true
            }
        }
        return false
    }

    /// Like `tapPickerRow` but taps the frontmost *hittable* match —
    /// needed inside a sheet when the screen underneath carries a row
    /// with the same label prefix ("Mảng kinh doanh" sits on the
    /// settings list behind the room sheet).
    private func tapFrontPickerRow(_ title: String) {
        let query = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", title))
        guard let element = hittableOrRevealed(query) else {
            XCTFail("picker '\(title)' missing")
            return
        }
        element.tap()
    }

    /// Taps the toolbar "Lưu" of the front sheet once it is enabled, then
    /// waits for the sheet to dismiss.
    private func saveSheet() {
        let save = app.buttons["Lưu"]
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "exists == true AND hittable == true AND enabled == true"),
            object: save)
        XCTAssertEqual(
            XCTWaiter.wait(for: [ready], timeout: 10), .completed,
            "Lưu button missing or still disabled")
        save.tap()
        waitForDisappearance(save, message: "sheet did not dismiss after Lưu")
    }

    /// Opens one of the four tabs.
    private func openTab(_ title: String) {
        let button = app.tabBars.buttons[title]
        XCTAssertTrue(waitReady(button, timeout: 10), "tab \(title) missing")
        button.tap()
    }

    /// Fills the account editor sheet (opened via "Thêm tài khoản").
    private func addAccount(name: String, kind: String, openingBalance: Int64) {
        tapWhenReady(app.buttons["Thêm tài khoản"], "add-account button missing")
        fillField(app.textFields["Tên tài khoản"], with: name)
        pickAccountKind(kind)
        if openingBalance > 0 {
            ensureKeypadVisible()
            typeAmount(openingBalance)
        }
        saveSheet()
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 5),
                      "account \(name) not listed")
    }

    /// Fills the credit-card section after `addAccount`'s common fields.
    private func addCreditCard(
        name: String,
        debt: Int64,
        creditLimit: String,
        statementDayIncrements: Int
    ) {
        tapWhenReady(app.buttons["Thêm tài khoản"], "add-account button missing")
        fillField(app.textFields["Tên tài khoản"], with: name)
        pickAccountKind("Thẻ tín dụng")
        ensureKeypadVisible()
        typeAmount(debt)

        fillField(app.textFields["Hạn mức"], with: creditLimit)
        stepperIncrements("Ngày chốt sao kê", by: statementDayIncrements)
        // Grace days already default to 15.
        saveSheet()
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 5),
                      "card \(name) not listed")
    }

    /// Fills the loan section after `addAccount`'s common fields.
    private func addLoan(
        name: String,
        debt: Int64,
        principal: String,
        rate: String,
        termMonths: String,
        paymentDayIncrements: Int
    ) {
        tapWhenReady(app.buttons["Thêm tài khoản"], "add-account button missing")
        fillField(app.textFields["Tên tài khoản"], with: name)
        pickAccountKind("Khoản vay")
        ensureKeypadVisible()
        typeAmount(debt)

        fillField(app.textFields["Số tiền vay gốc"], with: principal)
        fillField(app.textFields["Lãi suất (%/năm)"], with: rate)
        fillField(app.textFields["Kỳ hạn (tháng)"], with: termMonths)
        stepperIncrements("Ngày trả hằng tháng", by: paymentDayIncrements)
        saveSheet()
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 5),
                      "loan \(name) not listed")
    }

    /// A stepper whose label starts with `prefix` ("Ngày chốt sao kê: 15"),
    /// scrolled into view first — stepper labels carry the current value.
    private func stepperIncrements(_ prefix: String, by count: Int) {
        let stepper = app.steppers
            .matching(NSPredicate(format: "label BEGINSWITH %@", prefix))
            .firstMatch
        if !stepper.exists { _ = reveal(stepper) }
        XCTAssertTrue(stepper.exists, "stepper '\(prefix)…' missing")
        for _ in 0..<count {
            stepper.buttons["Increment"].tap()
        }
    }

    /// The "Loại tài khoản" navigation-link picker inside AccountEditView.
    private func pickAccountKind(_ kind: String) {
        tapPickerRow("Loại tài khoản")
        tapOption(kind)
    }

    /// Makes sure the form's amount keypad is on screen before typing.
    private func ensureKeypadVisible() {
        let one = app.buttons["1"]
        if !reveal(one, maxSwipes: 4) {
            XCTAssertTrue(one.waitForExistence(timeout: 3), "keypad missing")
        }
    }

    /// Taps a text field (scrolling to it if needed) and types into it.
    private func fillField(_ field: XCUIElement, with text: String) {
        if !reveal(field, maxSwipes: 6) {
            XCTAssertTrue(field.waitForExistence(timeout: 3), "field missing")
        }
        field.tap()
        app.typeText(text)
    }

    /// Taps a transaction row by its title — the row carries identifier
    /// `txList.row.<title>` (children stay visible for amount assertions).
    /// Falls back to the row's title text if the container element is not
    /// exposed as hittable.
    private func tapTransactionRow(_ title: String) {
        let row = app.descendants(matching: .any)["txList.row.\(title)"]
        if !reveal(row, maxSwipes: 6), !row.exists {
            // Identifier not exposed — try the title text itself.
            let text = app.staticTexts[title]
            if !reveal(text, maxSwipes: 6) {
                XCTAssertTrue(text.waitForExistence(timeout: 3),
                              "transaction row '\(title)' missing")
            }
            XCTAssertTrue(waitReady(text, timeout: 3),
                          "transaction row '\(title)' not hittable")
            text.tap()
            return
        }
        XCTAssertTrue(waitReady(row, timeout: 5),
                      "transaction row '\(title)' not hittable")
        row.tap()
    }

    /// Taps a list row whose combined accessibility label contains `text`
    /// (NavigationLink rows surface as buttons; plain rows via inner texts).
    private func tapRowAny(_ text: String) {
        let matches = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", text))
        guard let element = hittableOrRevealed(matches) else {
            XCTFail("row '\(text)' missing")
            return
        }
        element.tap()
    }

    /// Taps an option in a pushed picker list or popup menu — matched by its
    /// exact label among any element type (options surface as buttons or as
    /// plain rows depending on the screen).
    private func tapOption(_ name: String) {
        let matches = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", name))
        guard let element = hittableOrRevealed(matches) else {
            XCTFail("option '\(name)' missing")
            return
        }
        element.tap()
    }

    /// Frontmost hittable match of `query`; if none appears in time, swipes
    /// the front list and re-checks — far-off-screen rows are not even in the
    /// accessibility tree until they near the viewport.
    private func hittableOrRevealed(
        _ query: XCUIElementQuery
    ) -> XCUIElement? {
        if let element = firstHittableMatch(query, timeout: 5) {
            return element
        }
        for _ in 0..<10 {
            swipeUpIfAlive(frontScrollable())
            if let element = firstHittableMatch(query, timeout: 0.5) {
                return element
            }
        }
        return nil
    }

    /// Like `hittableOrRevealed` but swipes the tallest scroll view on
    /// screen — on the dashboard that is the outer ScrollView, whereas
    /// `frontScrollable()` can land on the accounts card's small
    /// horizontal scroller, whose gestures leak to the floating tab bar.
    private func hittableOrRevealedInOuter(
        _ query: XCUIElementQuery
    ) -> XCUIElement? {
        if let element = firstHittableMatch(query, timeout: 3) {
            return element
        }
        let scroller = app.scrollViews.allElementsBoundByIndex
            .max(by: { $0.frame.height < $1.frame.height })
            ?? (app as XCUIElement)
        for _ in 0..<12 {
            swipeUpIfAlive(scroller)
            if let element = firstHittableMatch(query, timeout: 0.4) {
                return element
            }
        }
        return nil
    }

    /// Waits for a button to be present, hittable AND enabled, then taps it —
    /// toolbar save buttons are disabled until the form is valid, and a tap
    /// on a still-disabled button is silently ignored. The generous timeout
    /// covers the app being busy persisting right after a sheet dismisses.
    private func tapWhenReady(
        _ element: XCUIElement,
        _ message: String,
        timeout: TimeInterval = 12,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "exists == true AND hittable == true AND enabled == true"),
            object: element)
        XCTAssertEqual(
            XCTWaiter.wait(for: [ready], timeout: timeout), .completed,
            message, file: file, line: line)
        element.tap()
    }

    /// Asserts an element is on screen — scrolls to materialize it first so
    /// no existence timeout is burned on a merely off-screen element.
    private func assertVisible(
        _ element: XCUIElement,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if !reveal(element) {
            XCTAssertTrue(element.waitForExistence(timeout: 3), message,
                          file: file, line: line)
        }
    }

    /// Navigates back to the screen titled `parentTitle`.
    private func goBack(to parentTitle: String) {
        let back = app.navigationBars.buttons[parentTitle]
        if back.waitForExistence(timeout: 3) {
            back.tap()
            return
        }
        let first = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(first.waitForExistence(timeout: 3), "back button missing")
        first.tap()
    }

    /// Confirms a destructive action sheet/confirmation dialog. First waits
    /// for the dialog's own title — only then is it safe to tap the button
    /// inside the sheet that contains that title (the form behind has an
    /// identically-labelled row; a tap through the scrim would dismiss the
    /// dialog without confirming).
    private func confirmDestructive(label: String, dialogTitle: String) {
        XCTAssertTrue(
            app.staticTexts[dialogTitle].waitForExistence(timeout: 5),
            "confirmation dialog missing")
        for index in stride(from: app.sheets.count - 1, through: 0, by: -1) {
            let sheet = app.sheets.element(boundBy: index)
            if sheet.staticTexts[dialogTitle].exists {
                let button = sheet.buttons[label]
                XCTAssertTrue(button.waitForExistence(timeout: 3),
                              "dialog button \(label) missing")
                button.tap()
                return
            }
        }
        // The dialog did not surface as a .sheet — fall back to the last
        // (frontmost) hittable button with this label.
        let button = lastHittable(app.buttons
            .matching(NSPredicate(format: "label == %@", label)))
        XCTAssertTrue(button.waitForExistence(timeout: 3),
                      "dialog button \(label) missing")
        button.tap()
    }

    // MARK: - Query helpers

    /// Element lookup by accessibility identifier regardless of type —
    /// `.accessibilityElement(children: .contain)` groups surface as `.other`.
    private func scopedElement(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// First hittable match of a query, scanned frontmost-first (later tree
    /// elements sit on top: menus, dialogs, pushed pages). Polls until one
    /// appears or `timeout` elapses; returns nil when nothing hittable ever
    /// matched.
    private func firstHittableMatch(
        _ query: XCUIElementQuery, timeout: TimeInterval
    ) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            for element in query.allElementsBoundByIndex.reversed()
            where element.isHittable {
                return element
            }
            if Date() >= deadline { return nil }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
    }

    /// Last hittable match of a query (frontmost), or `firstMatch`.
    private func lastHittable(_ query: XCUIElementQuery) -> XCUIElement {
        for element in query.allElementsBoundByIndex.reversed()
        where element.isHittable {
            return element
        }
        return query.firstMatch
    }

    /// The frontmost hittable list/scroll container — sheets come last in the
    /// accessibility tree, so a presented sheet's Form is preferred over the
    /// covered root list.
    private func frontScrollable() -> XCUIElement {
        if app.sheets.count > 0 {
            let sheet = app.sheets.element(boundBy: app.sheets.count - 1)
            for query in [sheet.collectionViews, sheet.scrollViews] {
                if let candidate = query.allElementsBoundByIndex
                    .last(where: { $0.isHittable }) {
                    return candidate
                }
            }
        }
        for query in [app.collectionViews, app.scrollViews] {
            for index in stride(from: query.count - 1, through: 0, by: -1) {
                let candidate = query.element(boundBy: index)
                if candidate.isHittable { return candidate }
            }
        }
        return app
    }

    /// Swipes up inside the front scrollable until `element` is actually
    /// hittable — `LazyVStack`/`List` children only materialize on screen, and
    /// rows near the edges can exist in the tree yet sit off-screen or under
    /// the floating tab bar, where a tap would land on the wrong element.
    @discardableResult
    private func reveal(_ element: XCUIElement, maxSwipes: Int = 8) -> Bool {
        var swipes = 0
        while !(element.exists && element.isHittable) && swipes < maxSwipes {
            swipeUpIfAlive(frontScrollable())
            swipes += 1
        }
        return element.exists && element.isHittable
    }

    /// Swipes only when the element still resolves — `frontScrollable()`
    /// returns an index-bound element and a push that settles between the
    /// pick and the swipe can drop one of the two lists, turning the
    /// gesture into an unrecoverable "no matches" failure.
    private func swipeUpIfAlive(_ element: XCUIElement) {
        if element.exists {
            element.swipeUp()
        }
    }

    /// Waits until `element` exists AND is hittable — taps must not land
    /// while a sheet is still dismissing or a pushed screen is animating.
    private func waitReady(
        _ element: XCUIElement, timeout: TimeInterval = 8
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"),
            object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForDisappearance(
        _ element: XCUIElement,
        message: String,
        timeout: TimeInterval = 12,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: element)
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: timeout), .completed,
            message, file: file, line: line)
    }
}
