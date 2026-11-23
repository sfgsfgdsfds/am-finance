import Testing
@testable import FinanceCore

struct BillSplitPlanTests {

    /// The headline example: 1,2 triệu chia đều 4 người (self + 3 bạn) —
    /// 300.000 mỗi người, tổng payer trả đúng 1.200.000.
    @Test func evenSplitOfTheCanonicalBill() throws {
        let plan = try BillSplit.plan(total: 1_200_000, participants: 4)
        #expect(plan.ownShare == 300_000)
        #expect(plan.friendShares == [300_000, 300_000, 300_000])
        #expect(plan.shares == [300_000, 300_000, 300_000, 300_000])
        #expect(plan.baseShare == 300_000)
        #expect(plan.remainder == 0)
    }

    /// Remainder đồng go one at a time in display order starting with
    /// self — never spread proportionally and never a float.
    @Test func remainderGoesToSelfFirst() throws {
        let plan = try BillSplit.plan(total: 1_200_001, participants: 4)
        #expect(plan.shares == [300_001, 300_000, 300_000, 300_000])
        #expect(plan.ownShare == 300_001)
        #expect(plan.friendShares == [300_000, 300_000, 300_000])
    }

    @Test func remainderDistributesInDisplayOrder() throws {
        let plan = try BillSplit.plan(total: 1_000_003, participants: 4)
        #expect(plan.shares == [250_001, 250_001, 250_001, 250_000])
        let two = try BillSplit.plan(total: 5, participants: 3)
        #expect(two.shares == [2, 2, 1])
    }

    /// Smallest legal bill: 2 đồng over 2 people is [1, 1] — still no
    /// zero share.
    @Test func smallestValidSplit() throws {
        let plan = try BillSplit.plan(total: 2, participants: 2)
        #expect(plan.shares == [1, 1])
        #expect(plan.friendShares == [1])
    }

    /// The shares must always sum back to the exact total — checked over
    /// a spread of totals and party sizes including awkward primes.
    @Test func sharesAlwaysSumToTotal() throws {
        let totals: [Int64] = [2, 3, 7, 999, 1_234_567, 10_000_001, Int64.max]
        for total in totals {
            for count in 2...10 where total >= Int64(count) {
                let plan = try BillSplit.plan(total: total, participants: count)
                #expect(plan.shares.reduce(0, +) == total)
                #expect(plan.shares.allSatisfy { $0 > 0 })
                // Shares differ by at most one đồng.
                #expect((plan.shares.max()! - plan.shares.min()!) <= 1)
            }
        }
    }

    /// Int64.max splits cleanly — no overflow anywhere in the chain.
    @Test func maxTotalDoesNotOverflow() throws {
        let plan = try BillSplit.plan(total: Int64.max, participants: 3)
        #expect(plan.shares.reduce(0, +) == Int64.max)
        #expect(plan.ownShare == Int64.max / 3 + 1)
    }

    // MARK: - Validation

    @Test func rejectsNonPositiveTotals() {
        #expect(throws: BillSplit.Error.nonPositiveTotal) {
            try BillSplit.plan(total: 0, participants: 4)
        }
        #expect(throws: BillSplit.Error.nonPositiveTotal) {
            try BillSplit.plan(total: -500_000, participants: 4)
        }
        #expect(throws: BillSplit.Error.nonPositiveTotal) {
            try BillSplit.plan(total: Int64.min, participants: 2)
        }
    }

    @Test func rejectsTooFewParticipants() {
        #expect(throws: BillSplit.Error.tooFewParticipants) {
            try BillSplit.plan(total: 1_200_000, participants: 1)
        }
        #expect(throws: BillSplit.Error.tooFewParticipants) {
            try BillSplit.plan(total: 1_200_000, participants: 0)
        }
        #expect(throws: BillSplit.Error.tooFewParticipants) {
            try BillSplit.plan(total: 1_200_000, participants: -3)
        }
    }

    /// `total < participants` would hand somebody a zero share — the
    /// policy forbids it outright.
    @Test func rejectsZeroShares() {
        #expect(throws: BillSplit.Error.shareWouldBeZero) {
            try BillSplit.plan(total: 3, participants: 4)
        }
        #expect(throws: BillSplit.Error.shareWouldBeZero) {
            try BillSplit.plan(total: 1, participants: 2)
        }
    }

    /// The participant count is untrusted input — the accepted range is
    /// bounded so no allocation can be sized by it.
    @Test func rejectsUntrustedCounts() {
        #expect(throws: BillSplit.Error.tooManyParticipants) {
            try BillSplit.plan(
                total: Int64.max, participants: BillSplit.maxParticipants + 1)
        }
        #expect(throws: BillSplit.Error.tooManyParticipants) {
            try BillSplit.plan(total: Int64.max, participants: .max)
        }
        // The boundary itself still plans — count fits an Int64.
        let plan = try? BillSplit.plan(
            total: Int64.max, participants: BillSplit.maxParticipants)
        #expect(plan?.participantCount == BillSplit.maxParticipants)
    }
}
