import Foundation
import Testing
@testable import FinanceCore

/// Wire-type round-trips against literal JSON written from the server's
/// sync contract (`api/internal/httpapi/sync.go`, `backup.go`).
struct SyncWireTypeTests {

    // MARK: - SyncEntity

    @Test func entityWireNamesMatchTheContract() {
        #expect(SyncEntity.allCases.map(\.rawValue) == [
            "account", "category", "business", "transaction",
            "loanRateChange", "budget", "recurringRule",
            "rentalUnit", "rentalLease",
        ])
    }

    @Test func applyOrderPutsParentsBeforeChildren() {
        #expect(SyncEntity.applyOrder == [
            .business, .account, .category, .rentalUnit, .rentalLease,
            .loanRateChange, .budget, .recurringRule, .transaction,
        ])
        #expect(SyncEntity.deleteOrder == SyncEntity.applyOrder.reversed())
        // Spot-check every FK edge seen in App/Models + BackupDocument:
        // child must apply strictly after its parents.
        let rank = Dictionary(
            uniqueKeysWithValues: SyncEntity.applyOrder.enumerated()
                .map { ($0.element, $0.offset) })
        let edges: [(SyncEntity, SyncEntity)] = [
            (.account, .business),          // account.businessID
            (.rentalUnit, .business),       // rentalUnit.businessID
            (.rentalLease, .rentalUnit),    // rentalLease.unitID
            (.loanRateChange, .account),    // loanRateChange.accountID
            (.budget, .category),           // budget.categoryID
            (.recurringRule, .account),     // accountID + toAccountID
            (.recurringRule, .category),    // categoryID
            (.recurringRule, .business),    // businessID
            (.transaction, .account),       // accountID + toAccountID
            (.transaction, .category),      // categoryID
            (.transaction, .business),      // businessID
            (.transaction, .rentalLease),   // rentalLeaseID
        ]
        for (child, parent) in edges {
            #expect(rank[child]! > rank[parent]!,
                    "\(child) must apply after \(parent)")
        }
    }

    // MARK: - Push request

    @Test func pushRequestEncodesExactlyTheContractShape() throws {
        let id = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        let request = SyncPushRequest(
            baseSeq: 42,
            changes: [
                SyncChange(
                    entity: .transaction, id: id, op: .upsert,
                    data: .object(["amount": .int(50_000)])),
                SyncChange(entity: .account, id: id, op: .delete),
            ])
        let encoded = try JSONEncoder().encode(request)
        let parsed = try SyncJSONValue(jsonData: encoded)
        #expect(parsed == .object([
            "base_seq": .int(42),
            "changes": .array([
                .object([
                    "entity": .string("transaction"),
                    "id": .string("11111111-2222-4333-8444-555555555555"),
                    "op": .string("upsert"),
                    "data": .object(["amount": .int(50_000)]),
                ]),
                // A delete emits no `data` key at all.
                .object([
                    "entity": .string("account"),
                    "id": .string("11111111-2222-4333-8444-555555555555"),
                    "op": .string("delete"),
                ]),
            ]),
        ]))
    }

    @Test func pushRequestDecodesLiteralJSON() throws {
        let request = try JSONDecoder().decode(
            SyncPushRequest.self,
            from: Data(#"""
            {"base_seq":7,"changes":[
              {"entity":"budget","id":"AAAAAAAA-1111-4111-8111-111111111111",
               "op":"upsert","data":{"monthlyLimit":2000000,"isActive":true}},
              {"entity":"budget","id":"aaaaaaaa-1111-4111-8111-111111111111",
               "op":"delete"}
            ]}
            """#.utf8))
        #expect(request.baseSeq == 7)
        #expect(request.changes.count == 2)
        #expect(request.changes[0].entity == .budget)
        #expect(request.changes[0].data == .object([
            "monthlyLimit": .int(2_000_000), "isActive": .bool(true),
        ]))
        #expect(request.changes[1].op == .delete)
        #expect(request.changes[1].data == nil)
        // Lowercase ids decode — the server accepts any case.
        #expect(request.changes[1].id
                == UUID(uuidString: "AAAAAAAA-1111-4111-8111-111111111111")!)
    }

    // MARK: - Push response

    @Test func pushResponseDecodesSeqAndSkippedResults() throws {
        let response = try JSONDecoder().decode(
            SyncPushResponse.self,
            from: Data(#"""
            {"high_water_seq":105,"results":[{"seq":104},{"skipped":true},{"seq":105}]}
            """#.utf8))
        #expect(response.highWaterSeq == 105)
        #expect(response.results == [.seq(104), .skipped, .seq(105)])
    }

    // MARK: - Pull response

    @Test func pullResponseDecodesRecordsAndTombstones() throws {
        let response = try JSONDecoder().decode(
            SyncPullResponse.self,
            from: Data(#"""
            {"records":[
              {"entity":"transaction","id":"AAAAAAAA-1111-4111-8111-111111111111",
               "seq":9,"data":{"kindRaw":"expense","amount":12000}},
              {"entity":"account","id":"BBBBBBBB-2222-4222-8222-222222222222",
               "seq":10,"deleted":true}],
             "next_cursor":10,"has_more":true}
            """#.utf8))
        #expect(response.nextCursor == 10)
        #expect(response.hasMore == true)
        #expect(response.records.count == 2)

        let live = response.records[0]
        #expect(live.syncEntity == .transaction)
        #expect(live.deleted == false)
        #expect(live.data == .object([
            "kindRaw": .string("expense"), "amount": .int(12_000),
        ]))

        let tombstone = response.records[1]
        #expect(tombstone.syncEntity == .account)
        #expect(tombstone.deleted == true)
        #expect(tombstone.data == nil)
        // The server emits UPPERCASE ids.
        #expect(tombstone.id
                == UUID(uuidString: "BBBBBBBB-2222-4222-8222-222222222222")!)
    }

    @Test func pullResponseDecodesMissingDeletedAsFalse() throws {
        let response = try JSONDecoder().decode(
            SyncPullResponse.self,
            from: Data(#"""
            {"records":[{"entity":"business","id":"CCCCCCCC-3333-4333-8333-333333333333",
             "seq":3,"data":{"name":"Phở"}}],"next_cursor":3,"has_more":false}
            """#.utf8))
        #expect(response.records[0].deleted == false)
        #expect(response.hasMore == false)
    }

    // MARK: - Error bodies

    @Test func conflictEnvelopeDecodes() throws {
        let envelope = try JSONDecoder().decode(
            SyncConflictEnvelope.self,
            from: Data(#"""
            {"error":"conflict","conflicts":[
              {"entity":"transaction","id":"DDDDDDDD-4444-4444-8444-444444444444","seq":77},
              {"entity":"category","id":"eeeeeeee-5555-4555-8555-555555555555","seq":78}]}
            """#.utf8))
        #expect(envelope.conflicts.count == 2)
        #expect(envelope.conflicts[0].syncEntity == .transaction)
        #expect(envelope.conflicts[0].seq == 77)
        #expect(envelope.conflicts[1].syncEntity == .category)
    }

    @Test func validationDetailDecodes() throws {
        let detail = try JSONDecoder().decode(
            SyncValidationDetail.self,
            from: Data(#"""
            {"error":"validation","index":2,"field":"amount",
             "constraint":"chk_positive","message":"change 2: amount must be > 0"}
            """#.utf8))
        #expect(detail.index == 2)
        #expect(detail.field == "amount")
        #expect(detail.constraint == "chk_positive")
        #expect(detail.message == "change 2: amount must be > 0")
    }

    @Test func validationDetailDefaultsBatchLevelIndex() throws {
        let detail = try JSONDecoder().decode(
            SyncValidationDetail.self,
            from: Data(#"""
            {"error":"validation","index":-1,"field":"formatVersion",
             "constraint":"","message":"unsupported formatVersion 9"}
            """#.utf8))
        #expect(detail.index == -1)
        #expect(detail.field == "formatVersion")
        #expect(detail.constraint == "")
    }

    @Test func errorEnvelopeDecodes() throws {
        let envelope = try JSONDecoder().decode(
            SyncErrorEnvelope.self,
            from: Data(#"{"error":"idempotency_key_reused"}"#.utf8))
        #expect(envelope.error == "idempotency_key_reused")
        #expect(envelope.message == nil)
    }

    // MARK: - Import summary

    @Test func importSummaryDecodes() throws {
        let summary = try JSONDecoder().decode(
            SyncImportSummary.self,
            from: Data(#"""
            {"entities":{
              "accounts":{"upserted":3,"tombstoned":1,"refs_nulled":0},
              "transactions":{"upserted":40,"tombstoned":2,"refs_nulled":1}},
             "ignored":["someFutureSection"]}
            """#.utf8))
        #expect(summary.entities["accounts"]
                == SyncImportEntitySummary(upserted: 3, tombstoned: 1, refsNulled: 0))
        #expect(summary.entities["transactions"]
                == SyncImportEntitySummary(upserted: 40, tombstoned: 2, refsNulled: 1))
        #expect(summary.ignored == ["someFutureSection"])
    }
}

/// `SyncJSONValue` parsing and the canonical hash the engine uses to
/// detect edits — the same record must hash identically whether it was
/// encoded by the app or rebuilt by the server.
struct SyncContentHashTests {

    @Test func parserCoversEveryJSONShape() throws {
        let value = try SyncJSONValue(jsonString: #"""
        {"a":[1,-2,3.5,1e3,null,true,false,"xA\n"],
         "b":{"nested":{"deep":[]}}}
        """#)
        #expect(value == .object([
            "a": .array([
                .int(1), .int(-2), .double(3.5), .double(1e3),
                .null, .bool(true), .bool(false), .string("xA\n"),
            ]),
            "b": .object(["nested": .object(["deep": .array([])])]),
        ]))
    }

    @Test func parserRejectsMalformedJSON() {
        for bad in [
            "", "{", "[1,]", "{\"a\":}", "tru", "01", "1e", "\"\\q\"",
            "{\"a\":1} trailing", "[1] extra", "\"\\ud800\"",
        ] {
            #expect(throws: SyncJSONError.malformedJSON) {
                try SyncJSONValue(jsonString: bad)
            }
        }
    }

    @Test func parserKeepsLargeIntegersExact() throws {
        let value = try SyncJSONValue(jsonString: "[9223372036854775807,-9223372036854775808]")
        #expect(value == .array([.int(.max), .int(.min)]))
    }

    @Test func parserUnescapesSurrogatePairs() throws {
        let value = try SyncJSONValue(jsonString: #""₫\u20AB \ud83d\ude00""#)
        #expect(value == .string("₫\u{20AB} \u{1F600}"))
    }

    @Test func codableRoundTripsTheAST() throws {
        let original: SyncJSONValue = .object([
            "n": .null,
            "i": .int(-4), "d": .double(2.5), "s": .string("s"),
            "a": .array([.bool(true)]),
            "o": .object(["k": .int(1)]),
        ])
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(SyncJSONValue.self, from: data) == original)
    }

    @Test func hashIgnoresObjectKeyOrder() throws {
        let lhs = try SyncJSONValue(jsonString: #"{"a":1,"b":{"x":true,"y":2}}"#)
        let rhs = try SyncJSONValue(jsonString: #"{"b":{"y":2,"x":true},"a":1}"#)
        #expect(SyncContentHasher.hash(lhs) == SyncContentHasher.hash(rhs))
    }

    @Test func hashNormalizesIntegerValuedDoubles() throws {
        let lhs = try SyncJSONValue(jsonString: #"{"v":12.0}"#)
        let rhs = try SyncJSONValue(jsonString: #"{"v":12}"#)
        #expect(SyncContentHasher.hash(lhs) == SyncContentHasher.hash(rhs))
    }

    @Test func hashNormalizesTimestampToMillisecondsZulu() throws {
        // The server truncates to `.sssZ`; a µs-precision or offset form
        // of the same instant must hash identically.
        let pushed = try SyncJSONValue(
            jsonString: #"{"createdAt":"2026-11-20T09:05:00.123Z"}"#)
        let precision = try SyncJSONValue(
            jsonString: #"{"createdAt":"2026-11-20T09:05:00.123999Z"}"#)
        let offset = try SyncJSONValue(
            jsonString: #"{"createdAt":"2026-11-20T16:05:00.123+07:00"}"#)
        let noFraction = try SyncJSONValue(
            jsonString: #"{"createdAt":"2026-11-20T09:05:00Z"}"#)
        #expect(SyncContentHasher.hash(pushed) == SyncContentHasher.hash(precision))
        #expect(SyncContentHasher.hash(pushed) == SyncContentHasher.hash(offset))
        #expect(SyncContentHasher.hash(pushed) != SyncContentHasher.hash(noFraction))
    }

    @Test func hashNormalizesUUIDCase() throws {
        let lhs = try SyncJSONValue(jsonString: #"{"id":"aaaaaaaa-1111-4111-8111-111111111111"}"#)
        let rhs = try SyncJSONValue(jsonString: #"{"id":"AAAAAAAA-1111-4111-8111-111111111111"}"#)
        #expect(SyncContentHasher.hash(lhs) == SyncContentHasher.hash(rhs))
    }

    @Test func hashDistinguishesRealChanges() throws {
        let lhs = try SyncJSONValue(jsonString: #"{"amount":50000}"#)
        for candidate in [
            #"{"amount":50001}"#, #"{"amount":"50000"}"#,
            #"{"amount":50000,"extra":null}"#, #"{"amount":50000.5}"#,
        ] {
            let rhs = try SyncJSONValue(jsonString: candidate)
            #expect(SyncContentHasher.hash(lhs) != SyncContentHasher.hash(rhs),
                    "\(candidate) must hash differently")
        }
    }

    @Test func hashIsStable64CharHex() throws {
        let hash = try SyncContentHasher.hash(jsonData: Data(#"{"a":1}"#.utf8))
        #expect(hash.count == 64)
        #expect(hash.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        // Same document, re-parsed, re-hashes identically.
        #expect(try SyncContentHasher.hash(jsonData: Data(#"{"a":1}"#.utf8)) == hash)
    }

    @Test func canonicalEncodingIsDeterministic() throws {
        let value = try SyncJSONValue(
            jsonString: #"{"z":[3.0,"café"],"a":-0.0,"m":12.5}"#)
        #expect(
            String(decoding: value.canonicalData(), as: UTF8.self)
            == #"{"a":0,"m":12.5,"z":[3,"café"]}"#)
    }

    @Test func fieldScalarsRenderByteIdenticalCanonicalJSON() throws {
        // The direct DTO-field encoder must produce the exact canonical
        // bytes the parse → canonicalize pipeline produces for the same
        // document — every scalar kind, one document.
        let id = UUID(uuidString: "AAAAAAAA-1111-4111-8111-111111111111")!
        // .9999s — the wire's ISO-8601 writer rounds to .000Z.
        let date = Date(timeIntervalSince1970: 1_800_000_000.9999)
        let wireDate = ISO8601DateFormatter()
        wireDate.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let fields: [(String, SyncCanonicalScalar)] = [
            // Deliberately unordered — sorting is the encoder's job.
            ("zeta", .string("café \"x\"\n")),
            ("id", .uuid(id)),
            ("amount", .int(45_000)),
            ("rate", .double(11.5)),
            ("whole", .double(12.0)),
            ("ok", .bool(true)),
            ("when", .date(date)),
            // A USER string that merely looks like a UUID is normalized
            // (lowercased) on both paths — same content rule.
            ("noteIDish", .string(id.uuidString)),
        ]
        let ast = SyncJSONValue.object([
            "zeta": .string("café \"x\"\n"),
            "id": .string(id.uuidString),
            "amount": .int(45_000),
            "rate": .double(11.5),
            "whole": .double(12.0),
            "ok": .bool(true),
            "when": .string(wireDate.string(from: date)),
            "noteIDish": .string(id.uuidString),
        ])
        let canonical = SyncContentHasher.canonicalData(fields: fields)
        #expect(canonical == ast.canonicalData())
        #expect(SyncContentHasher.hash(fields: fields)
                == SyncContentHasher.hash(ast))
        #expect(SyncContentHasher.hash(canonicalData: canonical)
                == SyncContentHasher.hash(ast))
    }

    @Test func fieldScalarDateRoundsLikeTheWireWriter() throws {
        // `SyncCanonicalScalar.date` mirrors ISO8601DateFormatter's
        // round-to-ms, not the parsed-string path's truncate-to-ms.
        let wireDate = ISO8601DateFormatter()
        wireDate.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for stamp in [
            1_800_000_000.0004,   // rounds down
            1_800_000_000.0005,   // rounds up (half away from zero)
            1_800_000_000.9999,   // crosses the second boundary
            1_800_000_000.1230,   // trailing zero stays ".123"
        ] {
            let date = Date(timeIntervalSince1970: stamp)
            let fields: [(String, SyncCanonicalScalar)] = [("when", .date(date))]
            let ast = SyncJSONValue.object([
                "when": .string(wireDate.string(from: date)),
            ])
            #expect(SyncContentHasher.canonicalData(fields: fields)
                    == ast.canonicalData(), "\(stamp) mismatch")
        }
    }

    @Test func fieldScalarDateMatchesTheWirePipelineForEveryMillisecond() {
        // Property-style sweep: for EVERY millisecond value — at sub-ms
        // offsets bracketing the .5µs rounding boundary, and pre-1970 —
        // the direct `.date` scalar must emit the exact canonical bytes
        // the encode → parse → canonicalize pipeline produces. Two
        // floating-point renderings once drifted a millisecond apart on
        // ~1-in-9 instants (local hash ≠ hash of the same record pulled
        // back); both now derive from one function.
        let wireDate = ISO8601DateFormatter()
        wireDate.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var instants: [Double] = []
        let subMilliseconds = [0.0, 0.0001, 0.0004, 0.0005, 0.0006, 0.0009]
        for second in [1_800_000_000.0, -1.0, -86_400.0, -31_557_600.0] {
            for ms in 0..<1_000 {
                for epsilon in subMilliseconds {
                    instants.append(second + Double(ms) / 1_000 + epsilon)
                }
            }
        }
        instants += [
            0.0, -0.0004, -0.0005, -0.0006,
            1_800_000_000.9994, 1_800_000_000.9995,
            -86_400.0004, -86_400.0005, -86_400.9995, -86_400.9999,
            -99_999_999.0001, 99_999_999.9999,
        ]
        for instant in instants {
            let date = Date(timeIntervalSince1970: instant)
            let ast = SyncJSONValue.object([
                "d": .string(wireDate.string(from: date)),
            ])
            let fields: [(String, SyncCanonicalScalar)] = [("d", .date(date))]
            #expect(
                SyncContentHasher.canonicalData(fields: fields)
                    == ast.canonicalData(),
                "t=\(instant) wire=\(wireDate.string(from: date))")
        }
    }
}

/// Diff of local-vs-shadow content hashes.
struct SyncDiffTests {

    private func key(_ entity: SyncEntity, _ id: String) -> SyncRecordKey {
        SyncRecordKey(entity: entity, id: UUID(uuidString: id)!)
    }

    private static let idA = "00000000-0000-4000-8000-00000000000A"
    private static let idB = "00000000-0000-4000-8000-00000000000B"
    private static let idC = "00000000-0000-4000-8000-00000000000C"

    @Test func unchangedSetsProduceAnEmptyDiff() {
        let local: [SyncRecordKey: String] = [
            key(.account, Self.idA): "h1", key(.transaction, Self.idB): "h2",
        ]
        let diff = SyncDiff.compute(local: local, shadow: local)
        #expect(diff.isEmpty)
    }

    @Test func newAndChangedKeysAreUpserts() {
        let diff = SyncDiff.compute(
            local: [
                key(.account, Self.idA): "new-hash",
                key(.transaction, Self.idB): "h2",
                key(.category, Self.idC): "h3",
            ],
            shadow: [
                key(.account, Self.idA): "old-hash",
                key(.transaction, Self.idB): "h2",
            ])
        #expect(diff.upserts == [
            key(.account, Self.idA),   // changed hash
            key(.category, Self.idC),  // missing from shadow
        ])
        #expect(diff.deletes.isEmpty)
    }

    @Test func shadowOnlyKeysAreDeletes() {
        let diff = SyncDiff.compute(
            local: [key(.account, Self.idA): "h1"],
            shadow: [
                key(.account, Self.idA): "h1",
                key(.transaction, Self.idB): "h2",
                key(.rentalLease, Self.idC): "h3",
            ])
        #expect(diff.upserts.isEmpty)
        #expect(diff.deletes == [
            key(.transaction, Self.idB),  // deepest child first…
            key(.rentalLease, Self.idC),  // …then its parent
        ])
    }

    @Test func orderingIsParentFirstForUpsertsChildFirstForDeletes() {
        // Inserted deliberately out of order; the diff sorts by the
        // entity apply/delete rank, then by id.
        let t1 = key(.transaction, "00000000-0000-4000-8000-0000000000FF")
        let acc = key(.account, Self.idA)
        let biz = key(.business, Self.idB)
        let t2 = key(.transaction, "00000000-0000-4000-8000-000000000001")
        let diff = SyncDiff.compute(
            local: [t1: "x", acc: "x", biz: "x", t2: "x"],
            shadow: [:])
        #expect(diff.upserts == [biz, acc, t2, t1])

        let gone = SyncDiff.compute(local: [:], shadow: [t1: "x", acc: "x", biz: "x"])
        #expect(gone.deletes == [t1, acc, biz])
    }
}

/// Push batching: at most 1000 changes and ~8 MiB per batch, no change
/// ever split.
struct SyncBatcherTests {

    private func change(_ index: Int) -> SyncChange {
        SyncChange(
            entity: .transaction,
            id: UUID(), op: .upsert,
            data: .object(["amount": .int(Int64(index))]))
    }

    @Test func emptyAndSmallInputsStayOneBatch() throws {
        #expect(try SyncBatcher.split([]).isEmpty)
        let batches = try SyncBatcher.split([change(1), change(2), change(3)])
        #expect(batches.count == 1)
        #expect(batches[0].count == 3)
    }

    @Test func changeCountLimitSplits() throws {
        let batches = try SyncBatcher.split(
            (0..<2_100).map(change), encodedSize: { _ in 10 })
        #expect(batches.map(\.count) == [1_000, 1_000, 100])
    }

    @Test func byteLimitSplitsWithoutBreakingAChange() throws {
        // ~1 MiB changes: (8 MiB − reserve) fits 8 per batch — the byte
        // cap binds long before the 1000-change cap.
        let changes = (0..<20).map(change)
        let batches = try SyncBatcher.split(changes, encodedSize: { _ in 1_000_000 })
        let perBatch = (SyncBatcher.byteLimit - 256) / 1_000_001
        #expect(batches.map(\.count) == [perBatch, perBatch, 20 - 2 * perBatch])
        // Order is preserved — batches concatenate back to the input.
        #expect(batches.flatMap { $0 }.map(\.id) == changes.map(\.id))
    }

    @Test func singleOversizedChangeFormsItsOwnBatch() throws {
        let big = SyncChange(
            entity: .transaction, id: UUID(), op: .upsert,
            data: .object(["note": .string(String(repeating: "x", count: 9 << 20))]))
        let batches = try SyncBatcher.split([change(1), big, change(2)])
        #expect(batches.map(\.count) == [1, 1, 1])
        #expect(batches[1].first?.id == big.id)
    }

    @Test func limitBoundariesAreExact() throws {
        // Byte check trips only when the next change would EXCEED the
        // limit: reserve + n*(size+1) <= limit stays in the batch.
        let fits = (SyncBatcher.byteLimit - 256) / 1_000_001
        let batches = try SyncBatcher.split(
            (0..<(fits + 2)).map(change), encodedSize: { _ in 1_000_000 })
        #expect(batches.map(\.count) == [fits, 2])
    }
}
