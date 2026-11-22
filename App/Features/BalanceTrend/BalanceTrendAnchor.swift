import Foundation
import FinanceCore

/// The two ways `BalanceTrendAnchorSheet` can reconcile a computed balance
/// with the real one the user reports.
enum BalanceTrendAnchorMode: String, CaseIterable, Identifiable, Sendable {
    /// Rewrite `Account.openingBalance` so history shifts onto the target.
    case openingBalance
    /// Insert one income/expense `LedgerTransaction` for the difference.
    case adjustmentTransaction

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openingBalance: return "Điều chỉnh số dư đầu kỳ"
        case .adjustmentTransaction: return "Tạo giao dịch điều chỉnh"
        }
    }

    /// One-line Vietnamese explanation shown under the option's name.
    var explanation: String {
        switch self {
        case .openingBalance:
            return "Đổi số dư đầu kỳ để số dư tính được khớp số thực tế. Không tạo giao dịch mới; toàn bộ lịch sử dịch chuyển cùng một mức — phù hợp với tài khoản nhập sao kê ngân hàng."
        case .adjustmentTransaction:
            return "Thêm một giao dịch thu/chi \"Điều chỉnh số dư\" đúng bằng phần chênh lệch. Số dư đầu kỳ được giữ nguyên."
        }
    }
}

/// Pure math behind "Đặt số dư thực tế": map the typed (non-negative) number
/// to a signed target, then work out either the new opening balance or the
/// adjustment transaction that makes the computed balance equal it. Nothing
/// is produced when the difference is 0 — both results stay nil.
///
/// Wraps `BalanceHistory.reconcile` so every subtraction is overflow-checked;
/// a result that cannot be represented comes back nil, never a trap.
enum BalanceTrendAnchor {

    /// The note written on the adjustment `LedgerTransaction`.
    static let adjustmentNote = "Điều chỉnh số dư"

    /// Signed target behind the non-negative number on the keypad: on a
    /// liability the user types the real debt ("Dư nợ thực tế"), which is a
    /// negative balance.
    static func signedTarget(typed: Int64, isLiability: Bool) -> Int64 {
        let magnitude = max(0, typed)
        return isLiability ? -magnitude : magnitude
    }

    /// `target - computed` — the signed delta the computed balance still
    /// needs. Nil on `Int64` overflow.
    static func adjustmentDelta(computed: Int64, target: Int64) -> Int64? {
        try? BalanceHistory.reconcile(computed: computed, reported: target).adjustmentDelta
    }

    /// `computed - target` in displayed terms — how far off the app's figure
    /// is, positive when the app overstates it. Nil on overflow.
    static func displayedDifference(computed: Int64, target: Int64, isLiability: Bool) -> Int64? {
        guard let delta = adjustmentDelta(computed: computed, target: target) else { return nil }
        // delta is `target - computed`; displayed terms flip both operands
        // for a liability, which flips the difference too.
        return BalanceTrendSeries.displayed(delta, isLiability: isLiability)
    }

    /// The opening balance that would make the computed balance exactly
    /// `target`: `opening + (target - computed)`. Nil when the difference is
    /// 0 (nothing to change) or the value does not fit `Int64`.
    static func newOpeningBalance(opening: Int64, computed: Int64, target: Int64) -> Int64? {
        guard let delta = adjustmentDelta(computed: computed, target: target), delta != 0 else {
            return nil
        }
        let (result, overflow) = opening.addingReportingOverflow(delta)
        return overflow ? nil : result
    }

    /// The adjustment transaction for `target`: an income for the missing
    /// amount or an expense for the excess. Nil when the difference is 0 or
    /// the magnitude does not fit `Int64`.
    static func adjustment(computed: Int64, target: Int64) -> (kind: TransactionKind, amount: Int64)? {
        guard let delta = adjustmentDelta(computed: computed, target: target), delta != 0 else {
            return nil
        }
        if delta > 0 { return (.income, delta) }
        let (magnitude, overflow) = Int64(0).subtractingReportingOverflow(delta)
        return overflow ? nil : (.expense, magnitude)
    }
}
