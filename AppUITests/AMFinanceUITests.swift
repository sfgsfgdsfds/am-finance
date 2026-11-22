import XCTest

/// End-to-end smoke tests for AM Finance. Every test launches the app fresh
/// with `-uiTestInMemoryStore` — a throwaway, seeded in-memory SwiftData
/// store — so real user data is never touched and tests stay independent.
///
/// Covers the smoke flow: the four tabs, quick-add (expense and income),
/// edit/delete, settings screens, accounts/cards/loans, debts and reports.
/// Vietnamese UI, VND amounts ("150.000 ₫").
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

    // MARK: - 1. Tabs render without crashing

    func testTabsRender() {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 15), "tab bar missing")
        for title in ["Tổng quan", "Giao dịch", "Nợ & Thẻ", "Báo cáo"] {
            XCTAssertTrue(tabBar.buttons[title].exists, "missing tab \(title)")
        }

        // Dashboard: the net-worth card renders.
        XCTAssertTrue(
            app.staticTexts["Tài sản ròng"].waitForExistence(timeout: 5),
            "dashboard net-worth card missing")

        openTab("Giao dịch")
        XCTAssertTrue(
            app.buttons["Tháng trước"].waitForExistence(timeout: 5),
            "transactions month switcher missing")

        openTab("Nợ & Thẻ")
        XCTAssertTrue(
            app.staticTexts["Chưa có thẻ hay khoản vay"].waitForExistence(timeout: 5)
                || app.staticTexts["Tổng dư nợ"].exists,
            "debts screen shows neither empty state nor totals")

        openTab("Báo cáo")
        for segment in ["Tháng", "Quý", "Năm"] {
            XCTAssertTrue(app.buttons[segment].waitForExistence(timeout: 5),
                          "reports segment \(segment) missing")
        }
    }

    // MARK: - 2. Quick add expense

    func testQuickAddExpense() throws {
        tapQuickAdd()
        typeAmount(150_000)
        pickCategory("Ăn nhậu")
        saveEditor()

        // The row is visible in "Giao dịch".
        openTab("Giao dịch")
        XCTAssertTrue(
            app.staticTexts["Ăn nhậu"].waitForExistence(timeout: 5),
            "transaction row missing in list")
        XCTAssertTrue(app.staticTexts["-150.000 ₫"].exists,
                      "expense amount missing in list")

        // … and in the dashboard's recent list.
        openTab("Tổng quan")
        let recentItem = scopedElement("dashboard.recentCard")
            .staticTexts["Ăn nhậu"]
        XCTAssertTrue(revealElement(recentItem),
                      "recent-transactions card does not show Ăn nhậu")

        // The month's expense shows 150.000.
        let monthCard = scopedElement("dashboard.monthCard")
        XCTAssertTrue(monthCard.waitForExistence(timeout: 5),
                      "month card missing")
        XCTAssertTrue(monthCard.staticTexts["-150.000 ₫"].exists,
                      "month expense does not show 150.000")
    }

    // MARK: - 3. Income with business

    func testIncomeWithBusiness() throws {
        tapQuickAdd()
        app.buttons["Thu"].tap()
        typeAmount(5_000_000)
        pickCategory("Doanh thu dịch vụ")
        pickBusiness("Làm web")
        saveEditor()

        let businessName = scopedElement("dashboard.businessCard")
            .staticTexts["Làm web"]
        XCTAssertTrue(revealElement(businessName),
                      "P&L card does not show business 'Làm web'")
    }

    // MARK: - 4. Edit and delete transactions

    func testEditAndDeleteTransactions() throws {
        quickAddExpense(amount: 100_000, category: "Ăn uống")
        quickAddExpense(amount: 50_000, category: "Di chuyển")

        openTab("Giao dịch")

        // Open the transaction, change the amount, save.
        tapRow(containing: "Ăn uống")
        XCTAssertTrue(
            app.navigationBars.staticTexts["Sửa giao dịch"]
                .waitForExistence(timeout: 5),
            "editor did not open")
        let amountToggle = app.buttons["Số tiền"]
        XCTAssertTrue(amountToggle.waitForExistence(timeout: 5),
                      "amount toggle missing")
        amountToggle.tap()  // reveal the keypad (hidden in edit mode)
        clearKeypad()
        typeAmount(120_000)
        saveEditor()

        XCTAssertTrue(
            app.staticTexts["-120.000 ₫"].waitForExistence(timeout: 5),
            "edited amount missing")
        XCTAssertFalse(app.staticTexts["-100.000 ₫"].exists,
                       "old amount still shown")

        // Delete another one via the editor.
        tapRow(containing: "Di chuyển")
        XCTAssertTrue(
            app.navigationBars.staticTexts["Sửa giao dịch"]
                .waitForExistence(timeout: 5),
            "editor did not open for delete")
        let deleteRow = app.buttons
            .matching(NSPredicate(format: "label == %@", "Xoá giao dịch"))
            .firstMatch
        XCTAssertTrue(revealElement(deleteRow),
                      "delete button missing in editor")
        deleteRow.tap()
        tapDialogButton("Xoá giao dịch")
        waitForDisappearance(app.staticTexts["Di chuyển"],
                             message: "deleted row still visible")
    }

    // MARK: - 5. Settings screens

    func testSettingsScreens() throws {
        // Gear on the dashboard → Cài đặt.
        let gear = app.buttons["Cài đặt"]
        XCTAssertTrue(gear.waitForExistence(timeout: 10), "settings gear missing")
        gear.tap()
        XCTAssertTrue(
            app.navigationBars.staticTexts["Cài đặt"].waitForExistence(timeout: 5),
            "settings screen missing")

        // Danh mục → add a category.
        tappable("Danh mục", exact: true).tap()
        XCTAssertTrue(
            app.navigationBars.staticTexts["Danh mục"].waitForExistence(timeout: 5),
            "categories screen missing")
        tapWhenReady(app.buttons["Thêm danh mục"], "add-category button missing")
        let nameField = app.textFields["Tên danh mục"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5),
                      "category name field missing")
        nameField.tap()
        app.typeText("Cafe sáng")
        tapWhenReady(app.buttons["Thêm"], "category save button missing")
        XCTAssertTrue(
            revealElement(app.staticTexts["Cafe sáng"]),
            "new category did not appear")
        goBack(to: "Cài đặt")

        // Mảng kinh doanh opens.
        tappable("Mảng kinh doanh").tap()
        XCTAssertTrue(
            app.navigationBars.staticTexts["Mảng kinh doanh"]
                .waitForExistence(timeout: 5),
            "businesses screen missing")
        goBack(to: "Cài đặt")

        // Sao lưu & khôi phục opens.
        tappable("Sao lưu & khôi phục").tap()
        XCTAssertTrue(
            app.navigationBars.staticTexts
                .matching(NSPredicate(format: "label BEGINSWITH %@", "Sao lưu"))
                .firstMatch.waitForExistence(timeout: 5),
            "backup screen missing")
        goBack(to: "Cài đặt")
        goBack(to: "Tổng quan")
    }

    // MARK: - 6 + 7. Accounts, cards, loans, debts

    func testAccountsAndDebts() throws {
        // Net worth card → accounts list.
        let netWorth = scopedElement("dashboard.netWorthCard")
        XCTAssertTrue(netWorth.waitForExistence(timeout: 10),
                      "net-worth card missing")
        netWorth.tap()
        XCTAssertTrue(
            app.navigationBars.staticTexts["Tài khoản"].waitForExistence(timeout: 5),
            "accounts screen missing")

        addAccount(
            name: "Ngân hàng ACB",
            kind: "Ngân hàng",
            openingBalance: 20_000_000)

        addCreditCard(
            name: "Thẻ Visa",
            debt: 2_000_000,
            creditLimit: "50000000",
            statementDayIncrements: 5)  // 15 → 20; grace stays at 15 days

        addLoan(
            name: "Vay mua xe",
            debt: 300_000_000,
            principal: "300000000",
            rate: "12",
            termMonths: "36",
            paymentDayIncrements: 4)  // 1 → 5

        // Open each account detail screen.
        for name in ["Ngân hàng ACB", "Thẻ Visa", "Vay mua xe"] {
            tapRow(containing: name)
            XCTAssertTrue(
                app.navigationBars.staticTexts[name].waitForExistence(timeout: 5),
                "detail for \(name) missing")
            goBack(to: "Tài khoản")
        }

        // The card's statement screen from the account detail.
        tapRow(containing: "Thẻ Visa")
        tapWhenReady(tappable("Sao kê & thanh toán thẻ"),
                     "card statement link missing")
        XCTAssertTrue(
            app.staticTexts["Sao kê gần nhất"].waitForExistence(timeout: 5)
                || revealElement(app.staticTexts["Sao kê gần nhất"]),
            "card statement section missing")
        goBack(to: "Thẻ Visa")  // back to account detail
        goBack(to: "Tài khoản") // back to the accounts list

        // Nợ & Thẻ: card and loan are listed.
        openTab("Nợ & Thẻ")
        XCTAssertTrue(app.staticTexts["Tổng dư nợ"].waitForExistence(timeout: 5),
                      "debts totals missing")
        XCTAssertTrue(app.staticTexts["Thẻ Visa"].exists, "card not listed")
        XCTAssertTrue(app.staticTexts["Vay mua xe"].exists, "loan not listed")

        // Card detail → record a payment from the bank account.
        tapRow(containing: "Thẻ Visa")
        let payButton = firstHittable(
            app.buttons.matching(NSPredicate(format: "label == %@", "Trả nợ thẻ")))
        XCTAssertTrue(payButton.waitForExistence(timeout: 5),
                      "card payment button missing")
        payButton.tap()
        XCTAssertTrue(
            app.navigationBars.staticTexts["Trả nợ thẻ"].waitForExistence(timeout: 5),
            "card payment sheet missing")
        tappable("Trả từ").tap()  // payer picker
        tappable("Ngân hàng ACB", exact: true).tap()
        saveSheet()

        // The payment transfer is recorded on the card.
        let paymentRow = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@", "Trả nợ thẻ Thẻ Visa"))
            .firstMatch
        XCTAssertTrue(
            paymentRow.waitForExistence(timeout: 5) || revealElement(paymentRow),
            "payment row missing on card detail")
        goBack(to: "Nợ & Thẻ")

        // Loan detail → repayment schedule is visible.
        tapRow(containing: "Vay mua xe")
        let schedule = app.staticTexts["Lịch trả nợ"]
        XCTAssertTrue(
            schedule.waitForExistence(timeout: 5) || revealElement(schedule),
            "loan schedule missing")
        goBack(to: "Nợ & Thẻ")

        // The payment shows up as a transfer in the transactions list.
        openTab("Giao dịch")
        let transferRow = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@", "Trả nợ thẻ Thẻ Visa"))
            .firstMatch
        XCTAssertTrue(
            transferRow.waitForExistence(timeout: 5) || revealElement(transferRow),
            "card payment missing in transactions")
    }

    // MARK: - 8. Reports

    func testReportsPeriodsAndScopes() throws {
        openTab("Báo cáo")

        let period = app.segmentedControls.firstMatch
        XCTAssertTrue(period.waitForExistence(timeout: 10),
                      "report period picker missing")
        for segment in ["Quý", "Năm", "Tháng"] {
            period.buttons[segment].tap()
            XCTAssertTrue(
                app.navigationBars.staticTexts["Báo cáo"].waitForExistence(timeout: 5),
                "reports screen lost after switching to \(segment)")
        }

        // Scope menu: Tất cả → Cá nhân → Làm web → Tất cả.
        let scope = app.buttons["Phạm vi báo cáo"]
        XCTAssertTrue(scope.waitForExistence(timeout: 5), "scope menu missing")
        for choice in ["Cá nhân", "Làm web", "Tất cả"] {
            scope.tap()
            tappable(choice, exact: true).tap()
            XCTAssertTrue(
                app.navigationBars.staticTexts["Báo cáo"].exists,
                "reports screen lost after scope \(choice)")
        }
    }

    // MARK: - Flow helpers

    /// Taps the floating "+" (accessibility label "Thêm giao dịch",
    /// identifier `root.quickAdd`) and waits for the editor sheet.
    private func tapQuickAdd() {
        let button = app.buttons["root.quickAdd"]
        XCTAssertTrue(button.waitForExistence(timeout: 10),
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
        saveEditor()
    }

    /// Types an amount on the đồng keypad — trailing "000" groups go through
    /// the dedicated key so large numbers take few taps.
    private func typeAmount(_ amount: Int64) {
        var digits = String(amount)
        var triples = 0
        while digits.hasSuffix("000") {
            digits.removeLast(3)
            triples += 1
        }
        for character in digits {
            let key = app.buttons[String(character)]
            XCTAssertTrue(key.waitForExistence(timeout: 3),
                          "keypad key \(character) missing")
            key.tap()
        }
        for _ in 0..<triples {
            app.buttons["000"].tap()
        }
    }

    /// Long-press the keypad's "Xoá" to clear the amount back to 0.
    private func clearKeypad() {
        let key = app.buttons["Xoá"]
        XCTAssertTrue(key.waitForExistence(timeout: 3), "keypad clear missing")
        key.press(forDuration: 0.8)
    }

    /// Scrolls inside the editor form until the category cell exists, then taps it.
    private func pickCategory(_ name: String) {
        let cell = app.buttons["txEditor.category.\(name)"]
        XCTAssertTrue(revealElement(cell), "category \(name) not found")
        cell.tap()
    }

    /// Picks a business in the editor's "Kinh doanh" navigation-link picker.
    private func pickBusiness(_ name: String) {
        let row = elementLabeled("Kinh doanh")
        if !row.exists || !row.isHittable {
            _ = revealElement(row)
        }
        XCTAssertTrue(row.exists, "business picker missing")
        row.tap()
        tappable(name, exact: true).tap()
    }

    /// Taps "Lưu" in the transaction editor and waits for the sheet to close.
    private func saveEditor() {
        saveSheet()
    }

    /// Taps the toolbar "Lưu" of the front sheet and waits for dismissal.
    private func saveSheet() {
        let save = app.buttons["Lưu"]
        XCTAssertTrue(waitForHittable(save, timeout: 5), "Lưu button missing")
        save.tap()
        waitForDisappearance(save, message: "sheet did not dismiss after Lưu")
    }

    /// Opens one of the four tabs.
    private func openTab(_ title: String) {
        let button = app.tabBars.buttons[title]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "tab \(title) missing")
        button.tap()
    }

    /// Fills the account editor sheet (opened via "Thêm tài khoản").
    private func addAccount(name: String, kind: String, openingBalance: Int64) {
        tapWhenReady(app.buttons["Thêm tài khoản"], "add-account button missing")
        let nameField = app.textFields["Tên tài khoản"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "name field missing")
        nameField.tap()
        app.typeText(name)
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
        let nameField = app.textFields["Tên tài khoản"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "name field missing")
        nameField.tap()
        app.typeText(name)
        pickAccountKind("Thẻ tín dụng")
        ensureKeypadVisible()
        typeAmount(debt)

        let limit = app.textFields["Hạn mức"]
        XCTAssertTrue(revealElement(limit), "credit-limit field missing")
        limit.tap()
        app.typeText(creditLimit)

        let stepper = stepper(prefix: "Ngày chốt sao kê")
        for _ in 0..<statementDayIncrements {
            stepper.buttons["Increment"].tap()
        }
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
        let nameField = app.textFields["Tên tài khoản"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "name field missing")
        nameField.tap()
        app.typeText(name)
        pickAccountKind("Khoản vay")
        ensureKeypadVisible()
        typeAmount(debt)

        let principalField = app.textFields["Số tiền vay gốc"]
        XCTAssertTrue(revealElement(principalField), "principal field missing")
        principalField.tap()
        app.typeText(principal)

        let rateField = app.textFields["Lãi suất (%/năm)"]
        rateField.tap()
        app.typeText(rate)

        let termField = app.textFields["Kỳ hạn (tháng)"]
        termField.tap()
        app.typeText(termMonths)

        let stepper = stepper(prefix: "Ngày trả hằng tháng")
        for _ in 0..<paymentDayIncrements {
            stepper.buttons["Increment"].tap()
        }
        saveSheet()
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 5),
                      "loan \(name) not listed")
    }

    /// The "Loại tài khoản" navigation-link picker inside AccountEditView.
    private func pickAccountKind(_ kind: String) {
        let row = elementLabeled("Loại tài khoản")
        if !row.exists || !row.isHittable {
            _ = revealElement(row)
        }
        XCTAssertTrue(row.exists, "account-kind picker missing")
        row.tap()
        tappable(kind, exact: true).tap()
    }

    /// Makes sure the form's amount keypad is on screen before typing.
    private func ensureKeypadVisible() {
        let one = app.buttons["1"]
        if !one.exists || !one.isHittable {
            _ = revealElement(one)
        }
    }

    /// A stepper whose label starts with `prefix` — stepper labels carry the
    /// current value ("Ngày chốt sao kê: 15"), so match the prefix.
    private func stepper(prefix: String) -> XCUIElement {
        let matches = app.steppers
            .matching(NSPredicate(format: "label BEGINSWITH %@", prefix))
        if let found = matches.allElementsBoundByIndex.first(where: { $0.isHittable }) {
            return found
        }
        let found = matches.firstMatch
        if !found.exists {
            _ = revealElement(found)
        }
        XCTAssertTrue(found.exists, "stepper '\(prefix)…' missing")
        return found
    }

    /// Taps a transaction/account row whose combined label contains `text`.
    private func tapRow(containing text: String) {
        let row = tappable(text)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "row '\(text)' missing")
        row.tap()
    }

    /// Waits then taps an element, asserting with `message` on timeout.
    private func tapWhenReady(
        _ element: XCUIElement,
        _ message: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), message,
                      file: file, line: line)
        element.tap()
    }

    /// Navigates back to the screen titled `parentTitle`.
    private func goBack(to parentTitle: String) {
        let back = app.navigationBars.buttons[parentTitle]
        if back.waitForExistence(timeout: 3) {
            back.tap()
            return
        }
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    /// Taps a button inside a presented confirmation dialog / action sheet.
    private func tapDialogButton(_ label: String) {
        for index in stride(from: app.sheets.count - 1, through: 0, by: -1) {
            let button = app.sheets.element(boundBy: index).buttons[label]
            if button.waitForExistence(timeout: 2) {
                button.tap()
                return
            }
        }
        // Fall back to the last hittable button with this label — the
        // dialog's button sits above the form's identical one.
        let matches = app.buttons
            .matching(NSPredicate(format: "label == %@", label))
        let button = lastHittable(matches)
        XCTAssertTrue(button.waitForExistence(timeout: 5),
                      "dialog button \(label) missing")
        button.tap()
    }

    // MARK: - Query helpers

    /// Element lookup by accessibility identifier regardless of type —
    /// `.accessibilityElement(children: .contain)` groups surface as `.other`.
    private func scopedElement(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// First hittable element (any type) whose label begins with `prefix` —
    /// Form Picker rows surface as buttons/static texts, not cells.
    private func elementLabeled(_ prefix: String) -> XCUIElement {
        let matches = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", prefix))
        for index in 0..<matches.count {
            let element = matches.element(boundBy: index)
            if element.isHittable { return element }
        }
        return matches.firstMatch
    }

    /// First hittable element whose label contains `text`, searched among
    /// buttons, then cells, then static texts — SwiftUI rows surface as
    /// different element types across iOS releases.
    private func tappable(_ text: String, exact: Bool = false) -> XCUIElement {
        let predicate = NSPredicate(
            format: exact ? "label == %@" : "label CONTAINS %@", text)
        for query in [app.buttons, app.cells, app.staticTexts] {
            let matches = query.matching(predicate)
            for index in 0..<matches.count {
                let element = matches.element(boundBy: index)
                if element.isHittable { return element }
            }
        }
        return app.buttons.matching(predicate).firstMatch
    }

    /// First hittable match of a query, or its `firstMatch` when none is.
    private func firstHittable(_ query: XCUIElementQuery) -> XCUIElement {
        for index in 0..<query.count {
            let element = query.element(boundBy: index)
            if element.isHittable { return element }
        }
        return query.firstMatch
    }

    /// Last hittable match of a query (frontmost), or `firstMatch`.
    private func lastHittable(_ query: XCUIElementQuery) -> XCUIElement {
        for index in stride(from: query.count - 1, through: 0, by: -1) {
            let element = query.element(boundBy: index)
            if element.isHittable { return element }
        }
        return query.firstMatch
    }

    /// The frontmost hittable list/scroll container — sheets and pushed
    /// screens come last in the accessibility tree.
    private func frontScrollable() -> XCUIElement {
        for query in [app.collectionViews, app.scrollViews] {
            for index in stride(from: query.count - 1, through: 0, by: -1) {
                let candidate = query.element(boundBy: index)
                if candidate.isHittable { return candidate }
            }
        }
        return app
    }

    /// Swipes up inside the front scrollable until `element` exists —
    /// `LazyVStack`/`List` children only materialize on screen.
    @discardableResult
    private func revealElement(_ element: XCUIElement, maxSwipes: Int = 12) -> Bool {
        var swipes = 0
        while !element.exists && swipes < maxSwipes {
            frontScrollable().swipeUp()
            swipes += 1
        }
        return element.exists
    }

    private func waitForHittable(
        _ element: XCUIElement, timeout: TimeInterval = 5
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"),
            object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForDisappearance(
        _ element: XCUIElement,
        message: String,
        timeout: TimeInterval = 5,
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
