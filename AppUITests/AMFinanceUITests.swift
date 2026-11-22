import XCTest

/// End-to-end smoke tests for AM Finance. Every test launches the app fresh
/// with `-uiTestInMemoryStore` — a throwaway, seeded in-memory SwiftData
/// store — so real user data is never touched.
///
/// The suite is grouped into three launches instead of one per flow — each
/// launch costs ~10-15 s of simulator + app idle time, so steps that can share
/// a store run together. Covers: the four tabs, quick-add (expense and
/// income), edit/delete, settings screens, accounts/cards/loans, debts and
/// reports. Vietnamese UI, VND amounts ("150.000 ₫").
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

    /// Frontmost hittable match of `query`; if none appears in time but
    /// matches exist off-screen, scrolls the front list and retries once.
    private func hittableOrRevealed(
        _ query: XCUIElementQuery
    ) -> XCUIElement? {
        if let element = firstHittableMatch(query, timeout: 5) {
            return element
        }
        guard let anyMatch = query.allElementsBoundByIndex.first else {
            return nil
        }
        _ = reveal(anyMatch, maxSwipes: 4)
        return firstHittableMatch(query, timeout: 2)
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

    /// Swipes up inside the front scrollable until `element` exists —
    /// `LazyVStack`/`List` children only materialize on screen.
    @discardableResult
    private func reveal(_ element: XCUIElement, maxSwipes: Int = 8) -> Bool {
        var swipes = 0
        while !element.exists && swipes < maxSwipes {
            frontScrollable().swipeUp()
            swipes += 1
        }
        return element.exists
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
