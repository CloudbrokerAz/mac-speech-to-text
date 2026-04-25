import Foundation
import Testing
@testable import SpeechToText

/// Pure-logic + filesystem tests for `AuditStore`. The PHI-leak
/// invariant (no transcript / SOAP body / patient name leaks into
/// `audit.jsonl`) is the security-critical assertion the issue body
/// calls out.
@Suite("AuditStore", .tags(.fast))
struct AuditStoreTests {
    /// Allowed JSON keys per `.claude/references/cliniko-api.md` §Audit.
    /// Any divergence is a schema change and requires a paired update of
    /// the reference doc + the EPIC's locked-decisions table.
    private static let allowedKeys: Set<String> = [
        "timestamp",
        "patient_id",
        "appointment_id",
        "note_id",
        "cliniko_status",
        "app_version"
    ]

    private static func makeRecord(
        timestamp: Date = Date(timeIntervalSince1970: 1_777_320_000),
        patientID: OpaqueClinikoID = OpaqueClinikoID(rawValue: "1001"),
        appointmentID: OpaqueClinikoID? = OpaqueClinikoID(rawValue: "5001"),
        noteID: OpaqueClinikoID = OpaqueClinikoID(rawValue: "9876543"),
        clinikoStatus: Int = 201,
        appVersion: String = "0.3.0"
    ) -> AuditRecord {
        AuditRecord(
            timestamp: timestamp,
            patientID: patientID,
            appointmentID: appointmentID,
            noteID: noteID,
            clinikoStatus: clinikoStatus,
            appVersion: appVersion
        )
    }

    private static func tempAuditURL() -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-store-tests-\(UUID().uuidString)", isDirectory: true)
        return folder.appendingPathComponent("audit.jsonl", isDirectory: false)
    }

    // MARK: - Round-trip

    @Test("Single record round-trips through append + loadAll")
    func record_thenLoadAll_returnsSameValue() async throws {
        let url = Self.tempAuditURL()
        let store = LocalAuditStore(fileURL: url)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let record = Self.makeRecord()
        try await store.record(record)
        let loaded = try await store.loadAll()

        #expect(loaded.count == 1)
        // Encoder uses iso8601 (second resolution); make the comparison
        // by re-encoding both records rather than relying on exact Date
        // equality across the encode/decode boundary.
        #expect(loaded.first == record.iso8601Truncated())
    }

    @Test("Multiple records preserve append order across separate record calls")
    func record_multipleCalls_preservesOrder() async throws {
        let url = Self.tempAuditURL()
        let store = LocalAuditStore(fileURL: url)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        for index in 0..<5 {
            try await store.record(Self.makeRecord(noteID: OpaqueClinikoID(rawValue: "note-\(index)")))
        }
        let loaded = try await store.loadAll()

        let expected = (0..<5).map { OpaqueClinikoID(rawValue: "note-\($0)") }
        #expect(loaded.map(\.noteID) == expected)
    }

    @Test("loadAll on a fresh store returns an empty array")
    func loadAll_beforeAnyRecord_returnsEmpty() async throws {
        let url = Self.tempAuditURL()
        let store = LocalAuditStore(fileURL: url)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let loaded = try await store.loadAll()

        #expect(loaded.isEmpty)
    }

    // MARK: - On-disk shape

    @Test("Each appended record produces exactly one JSONL line")
    func append_writesOneLinePerRecord() async throws {
        let url = Self.tempAuditURL()
        let store = LocalAuditStore(fileURL: url)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await store.record(Self.makeRecord(noteID: OpaqueClinikoID(rawValue: "first")))
        try await store.record(Self.makeRecord(noteID: OpaqueClinikoID(rawValue: "second")))
        try await store.record(Self.makeRecord(noteID: OpaqueClinikoID(rawValue: "third")))

        let raw = try Data(contentsOf: url)
        // Counting line-feed bytes — every record contributes a trailing
        // LF so the count equals the number of records when the file is
        // well-formed.
        let lineFeedCount = raw.filter { $0 == 0x0A }.count
        #expect(lineFeedCount == 3)
    }

    @Test("Encoded line keys are exactly the AuditRecord whitelist")
    func line_keysMatchWhitelist() async throws {
        let url = Self.tempAuditURL()
        let store = LocalAuditStore(fileURL: url)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await store.record(Self.makeRecord())
        let raw = try Data(contentsOf: url)
        let firstLine = try #require(raw.split(separator: 0x0A, omittingEmptySubsequences: true).first)
        let json = try JSONSerialization.jsonObject(with: Data(firstLine)) as? [String: Any]
        let keys = Set(try #require(json?.keys.map { $0 }))

        // No extra keys can sneak in (forward direction)…
        #expect(keys.isSubset(of: Self.allowedKeys))
        // …and every required key is present (no field accidentally
        // omitted on the disk shape — required for replay parsing).
        #expect(Self.allowedKeys.isSubset(of: keys))
    }

    @Test("On-disk JSONL line carries OpaqueClinikoID values as bare strings (#59)")
    func line_pins_opaque_id_byte_shape() async throws {
        // Integration-level pin for the #59 wire-shape invariant:
        // `OpaqueClinikoID` must encode as a bare JSON string, not as
        // a wrapping `{"rawValue":"…"}` object. The type-level test
        // (`OpaqueClinikoIDTests.codable_encodesAsBareString`) covers
        // a single-value encode; this one covers the integration via
        // `LocalAuditStore.makeEncoder()` so a future refactor that
        // drops the custom `Codable` methods on the type-level
        // doesn't pass the type-level test alone but break the
        // disk-shape invariant the audit ledger depends on.
        //
        // The fixture rawValues here are the digit-shaped Cliniko IDs
        // every production callsite uses (the picker writes
        // `OpaqueClinikoID(Int)`); we don't pin the wrapping-object
        // shape failure mode at this level because the type-level
        // test already does.
        let url = Self.tempAuditURL()
        let store = LocalAuditStore(fileURL: url)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await store.record(Self.makeRecord(
            patientID: OpaqueClinikoID(rawValue: "1001"),
            appointmentID: OpaqueClinikoID(rawValue: "5001"),
            noteID: OpaqueClinikoID(rawValue: "9876543")
        ))

        let raw = try Data(contentsOf: url)
        let line = try #require(String(data: raw, encoding: .utf8))

        // Bare-string fields, not wrapping objects.
        #expect(line.contains("\"patient_id\":\"1001\""))
        #expect(line.contains("\"appointment_id\":\"5001\""))
        #expect(line.contains("\"note_id\":\"9876543\""))

        // Negative pins — none of the wrapping-object byte sequences
        // a regression to `RawRepresentable`'s synthesised `Codable`
        // would emit.
        #expect(!line.contains("\"patient_id\":{"))
        #expect(!line.contains("\"appointment_id\":{"))
        #expect(!line.contains("\"note_id\":{"))
        #expect(!line.contains("\"rawValue\""))
    }

    @Test("Audit file is created with 0o600 permissions")
    func file_isCreatedWith0o600() async throws {
        let url = Self.tempAuditURL()
        let store = LocalAuditStore(fileURL: url)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await store.record(Self.makeRecord())
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let perms = try #require(attributes[.posixPermissions] as? NSNumber)

        #expect(perms.intValue == 0o600)
    }

    // MARK: - Corrupt-line tolerance
    //
    // The PHI-leak invariant is enforced by:
    // (a) `AuditRecord`'s schema — every field is a primitive that can't
    //     carry transcript / SOAP / patient-name content.
    // (b) `line_keysMatchWhitelist` — encoded JSONL keys are exactly the
    //     allowed set (any contributor widening the schema with a
    //     `note: String` field would fail this test even if all other
    //     fields stayed valid).
    // No third "string-search the bytes for PHI" test is added because
    // that assertion is structurally tautological today (no PHI flows
    // into `AuditRecord` to begin with) and gives false confidence.

    @Test("loadAll tolerates a corrupt trailing line (mid-write crash)")
    func loadAll_tolerates_corruptTrailingLine() async throws {
        let url = Self.tempAuditURL()
        let store = LocalAuditStore(fileURL: url)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await store.record(Self.makeRecord(noteID: OpaqueClinikoID(rawValue: "good-1")))
        try await store.record(Self.makeRecord(noteID: OpaqueClinikoID(rawValue: "good-2")))
        // Simulate a power-cut mid-write: append a partial line with no
        // trailing LF. Without tolerance, `loadAll` would throw on this
        // and the practitioner would lose visibility into every prior
        // export.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"timestamp":"2026"#.utf8))
        try handle.close()

        let loaded = try await store.loadAll()

        #expect(loaded.map(\.noteID) == [
            OpaqueClinikoID(rawValue: "good-1"),
            OpaqueClinikoID(rawValue: "good-2")
        ])
    }

    @Test("loadAll tolerates a corrupt middle line and surfaces the surrounding records")
    func loadAll_tolerates_corruptMiddleLine() async throws {
        let url = Self.tempAuditURL()
        let store = LocalAuditStore(fileURL: url)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await store.record(Self.makeRecord(noteID: OpaqueClinikoID(rawValue: "before")))
        // Corrupt middle line — synthesised by writing junk bytes
        // between two LF separators directly to the file.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not valid json\n".utf8))
        try handle.close()
        try await store.record(Self.makeRecord(noteID: OpaqueClinikoID(rawValue: "after")))

        let loaded = try await store.loadAll()

        #expect(loaded.map(\.noteID) == [
            OpaqueClinikoID(rawValue: "before"),
            OpaqueClinikoID(rawValue: "after")
        ])
    }

    // MARK: - InMemoryAuditStore parity

    @Test("InMemoryAuditStore round-trips records identically to LocalAuditStore")
    func inMemoryAuditStore_loadAll_returnsRecordedEntries() async throws {
        let store = InMemoryAuditStore()
        try await store.record(Self.makeRecord(noteID: OpaqueClinikoID(rawValue: "a")))
        try await store.record(Self.makeRecord(noteID: OpaqueClinikoID(rawValue: "b")))

        let loaded = try await store.loadAll()

        #expect(loaded.map(\.noteID) == [
            OpaqueClinikoID(rawValue: "a"),
            OpaqueClinikoID(rawValue: "b")
        ])
    }

    @Test("InMemoryAuditStore.reset clears recorded entries")
    func inMemoryAuditStore_reset_clearsEntries() async throws {
        let store = InMemoryAuditStore()
        try await store.record(Self.makeRecord(noteID: OpaqueClinikoID(rawValue: "a")))

        await store.reset()

        let loaded = try await store.loadAll()
        #expect(loaded.isEmpty)
    }

    @Test("InMemoryAuditStore.recordHook can simulate a write failure")
    func inMemoryAuditStore_recordHook_canThrow() async throws {
        struct TestError: Error {}
        let store = InMemoryAuditStore { _ in throw TestError() }

        do {
            try await store.record(Self.makeRecord())
            Issue.record("expected the hook to throw")
        } catch is TestError {
            // Append must NOT have happened — the hook fires before
            // append, so a thrown error leaves the store empty.
            let loaded = try await store.loadAll()
            #expect(loaded.isEmpty)
        }
    }
}

private extension AuditRecord {
    /// Truncate `timestamp` to whole seconds so equality holds across
    /// the iso8601 encoder (which drops sub-second precision). Keeps the
    /// test assertion semantic (same record value) without allocating an
    /// XCTAccuracy-style helper.
    func iso8601Truncated() -> AuditRecord {
        AuditRecord(
            timestamp: Date(timeIntervalSince1970: floor(timestamp.timeIntervalSince1970)),
            patientID: patientID,
            appointmentID: appointmentID,
            noteID: noteID,
            clinikoStatus: clinikoStatus,
            appVersion: appVersion
        )
    }
}
