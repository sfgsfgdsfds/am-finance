import Foundation

/// The nine ledger entities on the sync wire — wire names match the
/// server's `entities.go` metadata exactly.
public enum SyncEntity: String, Codable, CaseIterable, Sendable {
    case account
    case category
    case business
    case transaction
    case loanRateChange
    case budget
    case recurringRule
    case rentalUnit
    case rentalLease

    /// Parent-before-child order for applying (and pushing) changes:
    /// accounts and rental units need their business, leases their unit,
    /// rate changes and budgets their account/category, recurring rules
    /// and transactions all of the above. Verified against the SwiftData
    /// relationships in `App/Models` and `BackupRestorer`'s pass order.
    public static let applyOrder: [SyncEntity] = [
        .business,
        .account,
        .category,
        .rentalUnit,
        .rentalLease,
        .loanRateChange,
        .budget,
        .recurringRule,
        .transaction,
    ]

    /// Child-before-parent order — how deletes must travel so a parent's
    /// delete never precedes its children's.
    public static let deleteOrder: [SyncEntity] = applyOrder.reversed()

    /// Rank inside `applyOrder` — smaller applies first.
    public var applyRank: Int {
        SyncEntity.applyRanks[self]!
    }

    private static let applyRanks: [SyncEntity: Int] = {
        var ranks: [SyncEntity: Int] = [:]
        for (index, entity) in applyOrder.enumerated() {
            ranks[entity] = index
        }
        return ranks
    }()
}

/// Identity of one synced record — `(entity, id)` — used as the shadow
/// key and the diff output.
public struct SyncRecordKey: Hashable, Sendable {
    public var entity: SyncEntity
    public var id: UUID

    public init(entity: SyncEntity, id: UUID) {
        self.entity = entity
        self.id = id
    }

    /// Sorts by apply rank, then UUID string — the deterministic order a
    /// diff emits.
    static func applySort(_ lhs: SyncRecordKey, _ rhs: SyncRecordKey) -> Bool {
        if lhs.entity.applyRank != rhs.entity.applyRank {
            return lhs.entity.applyRank < rhs.entity.applyRank
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    /// Sorts by delete rank (children first), then UUID string.
    static func deleteSort(_ lhs: SyncRecordKey, _ rhs: SyncRecordKey) -> Bool {
        if lhs.entity.applyRank != rhs.entity.applyRank {
            return lhs.entity.applyRank > rhs.entity.applyRank
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

/// `upsert` carries the record's backup-v5 DTO in `data`; `delete`
/// carries none (the server ignores `data` on a delete).
public enum SyncChangeOp: String, Codable, Sendable {
    case upsert
    case delete
}

/// One entry of a push's `changes` array. `id` is the record's UUID; the
/// DTO inside `data` must carry the same `id`.
public struct SyncChange: Codable, Equatable, Sendable {
    public var entity: SyncEntity
    public var id: UUID
    public var op: SyncChangeOp
    public var data: SyncJSONValue?

    public init(entity: SyncEntity, id: UUID, op: SyncChangeOp, data: SyncJSONValue? = nil) {
        self.entity = entity
        self.id = id
        self.op = op
        self.data = data
    }
}

/// `POST /v1/sync/push` body: `{"base_seq": N, "changes": […]}`.
/// `baseSeq` is the pull cursor this batch was computed against.
public struct SyncPushRequest: Codable, Equatable, Sendable {
    public var baseSeq: Int64
    public var changes: [SyncChange]

    public init(baseSeq: Int64, changes: [SyncChange]) {
        self.baseSeq = baseSeq
        self.changes = changes
    }

    enum CodingKeys: String, CodingKey {
        case baseSeq = "base_seq"
        case changes
    }
}

/// One entry of the push response's `results` — either the server-assigned
/// seq (`{"seq": N}`) or the delete-was-a-no-op marker (`{"skipped": true}`).
public enum SyncPushResult: Equatable, Sendable {
    case seq(Int64)
    case skipped
}

extension SyncPushResult: Codable {
    private enum CodingKeys: String, CodingKey {
        case seq
        case skipped
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let seq = try container.decodeIfPresent(Int64.self, forKey: .seq) {
            self = .seq(seq)
        } else if try container.decodeIfPresent(Bool.self, forKey: .skipped) == true {
            self = .skipped
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .seq, in: container,
                debugDescription: "Expected {\"seq\": N} or {\"skipped\": true}")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .seq(let seq): try container.encode(seq, forKey: .seq)
        case .skipped: try container.encode(true, forKey: .skipped)
        }
    }
}

/// `200` body of a push: `{"high_water_seq": N, "results": […]}` — one
/// result per submitted change, in order.
public struct SyncPushResponse: Codable, Equatable, Sendable {
    public var highWaterSeq: Int64
    public var results: [SyncPushResult]

    public init(highWaterSeq: Int64, results: [SyncPushResult]) {
        self.highWaterSeq = highWaterSeq
        self.results = results
    }

    enum CodingKeys: String, CodingKey {
        case highWaterSeq = "high_water_seq"
        case results
    }
}

/// One record of the pull stream. `entity` stays a raw string — an
/// entity a newer server could add must not break decoding of the whole
/// page; `syncEntity` is the typed view.
public struct SyncPullRecord: Codable, Equatable, Sendable {
    public var entity: String
    public var id: UUID
    public var seq: Int64
    public var deleted: Bool
    public var data: SyncJSONValue?

    public init(
        entity: String, id: UUID, seq: Int64,
        deleted: Bool = false, data: SyncJSONValue? = nil
    ) {
        self.entity = entity
        self.id = id
        self.seq = seq
        self.deleted = deleted
        self.data = data
    }

    public var syncEntity: SyncEntity? { SyncEntity(rawValue: entity) }

    enum CodingKeys: String, CodingKey {
        case entity, id, seq, deleted, data
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entity = try container.decode(String.self, forKey: .entity)
        id = try container.decode(UUID.self, forKey: .id)
        seq = try container.decode(Int64.self, forKey: .seq)
        deleted = try container.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        data = try container.decodeIfPresent(SyncJSONValue.self, forKey: .data)
    }
}

/// `200` body of `GET /v1/sync/pull`: `{"records": […],
/// "next_cursor": N, "has_more": bool}`.
public struct SyncPullResponse: Codable, Equatable, Sendable {
    public var records: [SyncPullRecord]
    public var nextCursor: Int64
    public var hasMore: Bool

    public init(records: [SyncPullRecord], nextCursor: Int64, hasMore: Bool) {
        self.records = records
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }

    enum CodingKeys: String, CodingKey {
        case records
        case nextCursor = "next_cursor"
        case hasMore = "has_more"
    }
}

/// One row of the `409` conflict body: `{"entity", "id", "seq"}` — the
/// record's current server seq, which is `> base_seq`.
public struct SyncConflict: Codable, Equatable, Sendable {
    public var entity: String
    public var id: UUID
    public var seq: Int64

    public init(entity: String, id: UUID, seq: Int64) {
        self.entity = entity
        self.id = id
        self.seq = seq
    }

    public var syncEntity: SyncEntity? { SyncEntity(rawValue: entity) }
}

/// The `409` body itself: `{"error": "conflict", "conflicts": […]}`.
public struct SyncConflictEnvelope: Decodable, Equatable, Sendable {
    public var conflicts: [SyncConflict]

    public init(conflicts: [SyncConflict]) {
        self.conflicts = conflicts
    }
}

/// The `422 {"error": "validation", …}` payload. `index` is the failing
/// change's position in the batch (`-1` = batch-level); `field` and
/// `constraint` may be empty.
public struct SyncValidationDetail: Codable, Equatable, Sendable {
    public var index: Int
    public var field: String
    public var constraint: String
    public var message: String

    public init(index: Int, field: String, constraint: String, message: String) {
        self.index = index
        self.field = field
        self.constraint = constraint
        self.message = message
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decodeIfPresent(Int.self, forKey: .index) ?? -1
        field = try container.decodeIfPresent(String.self, forKey: .field) ?? ""
        constraint = try container.decodeIfPresent(String.self, forKey: .constraint) ?? ""
        message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
    }
}

/// The shared `{"error": "…"}` envelope shape — `bad_request`,
/// `idempotency_key_reused`, `request_too_large`,
/// `unsupported_media_type`, `unauthorized`, `internal`.
public struct SyncErrorEnvelope: Decodable, Equatable, Sendable {
    public var error: String
    public var message: String?

    public init(error: String, message: String? = nil) {
        self.error = error
        self.message = message
    }
}

/// `200` body of `POST /v1/backup/import`: per-section counters plus the
/// unknown top-level keys the server ignored.
public struct SyncImportSummary: Codable, Equatable, Sendable {
    public var entities: [String: SyncImportEntitySummary]
    public var ignored: [String]

    public init(entities: [String: SyncImportEntitySummary], ignored: [String]) {
        self.entities = entities
        self.ignored = ignored
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entities = try container.decodeIfPresent(
            [String: SyncImportEntitySummary].self, forKey: .entities) ?? [:]
        ignored = try container.decodeIfPresent([String].self, forKey: .ignored) ?? []
    }
}

/// One entity section's import counters.
public struct SyncImportEntitySummary: Codable, Equatable, Sendable {
    public var upserted: Int
    public var tombstoned: Int
    public var refsNulled: Int

    public init(upserted: Int, tombstoned: Int, refsNulled: Int) {
        self.upserted = upserted
        self.tombstoned = tombstoned
        self.refsNulled = refsNulled
    }

    enum CodingKeys: String, CodingKey {
        case upserted
        case tombstoned
        case refsNulled = "refs_nulled"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        upserted = try container.decodeIfPresent(Int.self, forKey: .upserted) ?? 0
        tombstoned = try container.decodeIfPresent(Int.self, forKey: .tombstoned) ?? 0
        refsNulled = try container.decodeIfPresent(Int.self, forKey: .refsNulled) ?? 0
    }
}

/// The change list produced by comparing local content hashes against the
/// shadow copy — what was last in sync with the server.
public struct SyncDiff: Equatable, Sendable {
    /// New or locally-changed records to push — parents first.
    public var upserts: [SyncRecordKey]
    /// Records present in the shadow but gone locally — children first.
    public var deletes: [SyncRecordKey]

    public init(upserts: [SyncRecordKey], deletes: [SyncRecordKey]) {
        self.upserts = upserts
        self.deletes = deletes
    }

    public var isEmpty: Bool { upserts.isEmpty && deletes.isEmpty }

    /// Diff `local` (every live row's key → content hash) against `shadow`
    /// (the last in-sync hashes). Equal hashes are unchanged; a local key
    /// with a different or missing shadow hash is an upsert; a shadow key
    /// with no local counterpart is a delete. Ordering is deterministic:
    /// upserts parent-first, deletes child-first, UUID-sorted inside each
    /// entity.
    public static func compute(
        local: [SyncRecordKey: String],
        shadow: [SyncRecordKey: String]
    ) -> SyncDiff {
        let upserts = local.keys
            .filter { shadow[$0] != local[$0] }
            .sorted(by: SyncRecordKey.applySort)
        let deletes = shadow.keys
            .filter { local[$0] == nil }
            .sorted(by: SyncRecordKey.deleteSort)
        return SyncDiff(upserts: upserts, deletes: deletes)
    }
}

/// Splits a change list into push-sized batches: at most
/// `changeLimit` changes and `byteLimit` encoded bytes per batch, in
/// order. A change never straddles two batches; one change bigger than
/// `byteLimit` forms its own batch (the server will answer 413).
public enum SyncBatcher {
    /// The server's hard cap on `changes` per push.
    public static let changeLimit = 1_000
    /// Encoded-size budget per batch — 8 MiB under the 10 MiB server cap,
    /// leaving headroom for the envelope.
    public static let byteLimit = 8 << 20
    /// `{"base_seq":0,"changes":[…]}` plus separators, generously.
    private static let envelopeReserve = 256

    /// `encodedSize` measures one change's JSON size (default: a
    /// `JSONEncoder` pass over `SyncChange`). Sizes include a byte for
    /// the array comma.
    public static func split(
        _ changes: [SyncChange],
        encodedSize: (SyncChange) throws -> Int = {
            (try JSONEncoder().encode($0)).count
        }
    ) throws -> [[SyncChange]] {
        var batches: [[SyncChange]] = []
        var current: [SyncChange] = []
        var currentBytes = envelopeReserve
        for change in changes {
            let size = try encodedSize(change) + 1
            if !current.isEmpty
                && (current.count >= changeLimit || currentBytes + size > byteLimit) {
                batches.append(current)
                current = []
                currentBytes = envelopeReserve
            }
            current.append(change)
            currentBytes += size
        }
        if !current.isEmpty {
            batches.append(current)
        }
        return batches
    }
}
