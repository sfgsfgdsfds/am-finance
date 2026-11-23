/// Equal-split "chia bill" policy for đồng amounts — pure `Int64`
/// arithmetic, no floats anywhere in the chain.
///
/// A bill is split evenly across a party that always includes the payer
/// themselves (index 0, "self") plus their friends in display order. The
/// split is exact: every share is `base` or `base + 1` đồng, the
/// remainder is handed out one đồng at a time starting with self, and
/// the shares always sum back to the bill total.
public enum BillSplit {

    /// Why a split cannot be planned.
    public enum Error: Swift.Error, Equatable, Sendable {
        /// Total must be a positive đồng magnitude.
        case nonPositiveTotal
        /// A split needs at least two people (self plus one friend).
        case tooFewParticipants
        /// `total < participants` would leave somebody a zero share.
        case shareWouldBeZero
        /// `participants > maxParticipants` — the count is untrusted
        /// input, so the accepted range is bounded on purpose.
        case tooManyParticipants
    }

    /// Largest party a plan accepts. Splitting a bill is a human flow —
    /// a thousand participants is already absurd — and the bound means
    /// no allocation anywhere is ever sized by an untrusted count.
    public static let maxParticipants = 1_000

    /// One computed equal split: `total` đồng over `participantCount`
    /// people. Participant 0 is the payer; the rest are the friends, in
    /// display order.
    public struct Plan: Equatable, Sendable {
        /// The bill total the shares sum back to (đồng).
        public let total: Int64
        /// Everyone sharing the bill, self included (≥ 2).
        public let participantCount: Int
        /// `total / participantCount` — every share is this or +1 đồng.
        public let baseShare: Int64
        /// `total % participantCount` — extra đồng handed out one at a
        /// time, in display order, starting with self.
        public let remainder: Int64

        /// The payer's own share — the first remainder đồng lands here.
        public var ownShare: Int64 { share(at: 0) }

        /// Share of the participant at `index` (0 is self, display
        /// order). Equal to `baseShare` plus one đồng while the
        /// remainder lasts.
        public func share(at index: Int) -> Int64 {
            precondition(
                index >= 0 && index < participantCount,
                "BillSplit share index out of range")
            return baseShare + (Int64(index) < remainder ? 1 : 0)
        }

        /// Every share in display order — `ownShare` first. Materialized
        /// per call; `participantCount` is bounded by `maxParticipants`,
        /// so this can never grow past a few KB.
        public var shares: [Int64] {
            (0..<participantCount).map { share(at: $0) }
        }

        /// The friends' shares only, in display order — `ownShare`
        /// excluded.
        public var friendShares: [Int64] {
            (1..<participantCount).map { share(at: $0) }
        }
    }

    /// Validates `total` and `participants`, then returns the plan.
    ///
    /// Rules: `total` and `participants` are both positive, the party is
    /// at least two people and at most `maxParticipants`, and
    /// `total >= participants` so no share can come out as zero.
    /// Division of positive `Int64`s cannot overflow, and each share is
    /// `base` or `base + 1`, so `ownShare + friendShares.sum == total`
    /// always holds.
    public static func plan(total: Int64, participants: Int) throws -> Plan {
        guard total > 0 else { throw Error.nonPositiveTotal }
        guard participants >= 2 else { throw Error.tooFewParticipants }
        guard participants <= maxParticipants
        else { throw Error.tooManyParticipants }
        guard total >= Int64(participants) else { throw Error.shareWouldBeZero }
        return Plan(
            total: total,
            participantCount: participants,
            baseShare: total / Int64(participants),
            remainder: total % Int64(participants)
        )
    }
}
