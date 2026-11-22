import Testing
@testable import FinanceCore

struct AccountKindTests {
    @Test func rawValues() {
        #expect(AccountKind.cash.rawValue == "cash")
        #expect(AccountKind.bank.rawValue == "bank")
        #expect(AccountKind.eWallet.rawValue == "eWallet")
        #expect(AccountKind.creditCard.rawValue == "creditCard")
        #expect(AccountKind.loan.rawValue == "loan")
        #expect(AccountKind.allCases == [.cash, .bank, .eWallet, .creditCard, .loan])
    }

    @Test func liabilities() {
        #expect(AccountKind.cash.isLiability == false)
        #expect(AccountKind.bank.isLiability == false)
        #expect(AccountKind.eWallet.isLiability == false)
        #expect(AccountKind.creditCard.isLiability)
        #expect(AccountKind.loan.isLiability)
    }

    @Test func displayNames() {
        #expect(AccountKind.cash.displayName == "Tiền mặt")
        #expect(AccountKind.bank.displayName == "Ngân hàng")
        #expect(AccountKind.eWallet.displayName == "Ví điện tử")
        #expect(AccountKind.creditCard.displayName == "Thẻ tín dụng")
        #expect(AccountKind.loan.displayName == "Khoản vay")
    }

    @Test func defaultSymbols() {
        for kind in AccountKind.allCases {
            #expect(kind.defaultSymbol.isEmpty == false)
        }
    }
}

struct TransactionKindTests {
    @Test func rawValues() {
        #expect(TransactionKind.expense.rawValue == "expense")
        #expect(TransactionKind.income.rawValue == "income")
        #expect(TransactionKind.transfer.rawValue == "transfer")
        #expect(TransactionKind.allCases == [.expense, .income, .transfer])
    }

    @Test func displayNames() {
        #expect(TransactionKind.expense.displayName == "Chi")
        #expect(TransactionKind.income.displayName == "Thu")
        #expect(TransactionKind.transfer.displayName == "Chuyển khoản")
    }
}

struct CategoryKindTests {
    @Test func rawValues() {
        #expect(CategoryKind.expense.rawValue == "expense")
        #expect(CategoryKind.income.rawValue == "income")
        #expect(CategoryKind.allCases == [.expense, .income])
    }
}

struct LedgerMathTests {
    @Test func expenseTakesFromSource() {
        #expect(LedgerMath.delta(kind: .expense, amount: 100_000, role: .source) == -100_000)
        #expect(LedgerMath.delta(kind: .expense, amount: 100_000, role: .destination) == 0)
    }

    @Test func incomeAddsToSource() {
        #expect(LedgerMath.delta(kind: .income, amount: 100_000, role: .source) == 100_000)
        #expect(LedgerMath.delta(kind: .income, amount: 100_000, role: .destination) == 0)
    }

    @Test func transferMovesBetweenAccounts() {
        #expect(LedgerMath.delta(kind: .transfer, amount: 100_000, role: .source) == -100_000)
        #expect(LedgerMath.delta(kind: .transfer, amount: 100_000, role: .destination) == 100_000)
    }

    @Test func balanceAddsDeltasToOpening() {
        #expect(LedgerMath.balance(opening: 1_000_000, deltas: []) == 1_000_000)
        #expect(LedgerMath.balance(opening: 1_000_000, deltas: [-100_000, 500_000, -200_000]) == 1_200_000)
    }

    @Test func creditCardPurchasePushesBalanceNegative() {
        // A purchase on the card is an expense sourced from the card.
        let purchase = LedgerMath.delta(kind: .expense, amount: 1_500_000, role: .source)
        #expect(LedgerMath.balance(opening: 0, deltas: [purchase]) == -1_500_000)
    }

    @Test func cardPaymentIsATransferIntoTheCard() {
        let out = LedgerMath.delta(kind: .transfer, amount: 1_500_000, role: .source)
        let into = LedgerMath.delta(kind: .transfer, amount: 1_500_000, role: .destination)
        #expect(LedgerMath.balance(opening: 5_000_000, deltas: [out]) == 3_500_000)   // bank
        #expect(LedgerMath.balance(opening: -1_500_000, deltas: [into]) == 0)          // card
    }

    @Test func loanRepaymentIsATransferIntoTheLoan() {
        // Loans start negative; a repayment moves the balance towards zero.
        let repayment = LedgerMath.delta(kind: .transfer, amount: 500_000, role: .destination)
        #expect(LedgerMath.balance(opening: -10_000_000, deltas: [repayment]) == -9_500_000)
    }
}
