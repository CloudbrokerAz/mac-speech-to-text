import Foundation
import XCTest
@testable import SpeechToText

/// End-to-end tests for `TreatmentNoteExporter` against
/// `URLProtocolStub`. Pins the export contract: happy path records
/// audit; every error surface bubbles a typed `ClinikoError` and leaves
/// `AuditStore` empty. The no-auto-retry-on-write contract from
/// `.claude/references/cliniko-api.md` §"Retry policy" is verified by
/// asserting the responder runs exactly once on 5xx / transport
/// failures.
final class TreatmentNoteExporterTests: XCTestCase {

    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    // MARK: - Helpers

    private var credentials: ClinikoCredentials {
        // swiftlint:disable:next force_try
        try! ClinikoCredentials(apiKey: "MS-test-au1", shard: .au1)
    }

    private func makeSession(responder: @escaping URLProtocolStub.Responder) -> URLSession {
        let config = URLProtocolStub.install(responder)
        return URLSession(configuration: config)
    }

    private func makeManipulations() -> ManipulationsRepository {
        ManipulationsRepository(all: [
            Manipulation(id: "diversified_hvla", displayName: "Diversified HVLA", clinikoCode: nil),
            Manipulation(id: "drop_table", displayName: "Drop-Table Technique", clinikoCode: nil)
        ])
    }

    private func makeNotes() -> StructuredNotes {
        StructuredNotes(
            subjective: "Patient reports lower-back pain after gardening.",
            objective: "ROM reduced; tender at L4-L5.",
            assessment: "Mechanical low back pain.",
            plan: "Diversified HVLA + home stretching plan.",
            selectedManipulationIDs: ["diversified_hvla", "drop_table"]
        )
    }

    private func makeExporter(
        session: URLSession,
        auditStore: any AuditStore = InMemoryAuditStore(),
        appVersion: String = "0.3.0-test",
        now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_777_320_000) }
    ) -> TreatmentNoteExporter {
        let client = ClinikoClient(
            credentials: credentials,
            session: session,
            userAgent: "exporter-tests/1.0",
            retryPolicy: .immediate
        )
        return TreatmentNoteExporter(
            client: client,
            auditStore: auditStore,
            manipulations: makeManipulations(),
            appVersion: appVersion,
            now: now
        )
    }

    // MARK: - Happy path

    func test_export_201_decodesNoteID_andRecordsAuditEntry() async throws {
        let captured = CapturedRequest()
        let session = makeSession { request in
            captured.set(request)
            let body = try HTTPStubFixture.load("cliniko/responses/treatment_notes_create.json")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 201,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, body)
        }
        let auditStore = InMemoryAuditStore()
        let exporter = makeExporter(session: session, auditStore: auditStore)

        let outcome = try await exporter.export(
            notes: makeNotes(),
            patientID: 1001,
            appointmentID: 5001
        )

        XCTAssertEqual(outcome.created.id, 9876543)
        XCTAssertTrue(outcome.auditPersisted)
        XCTAssertTrue(outcome.droppedManipulationIDs.isEmpty)

        let audit = try await auditStore.loadAll()
        XCTAssertEqual(audit.count, 1)
        let entry = try XCTUnwrap(audit.first)
        // ID fields are `OpaqueClinikoID` (#59); the exporter type-tags
        // the wire-shape Int into the opaque form when building the
        // audit row. Wire format on disk is unchanged (bare strings).
        XCTAssertEqual(entry.patientID, OpaqueClinikoID(1001))
        XCTAssertEqual(entry.appointmentID, OpaqueClinikoID(5001))
        XCTAssertEqual(entry.noteID, OpaqueClinikoID(9876543))
        XCTAssertEqual(entry.clinikoStatus, 201)
        XCTAssertEqual(entry.appVersion, "0.3.0-test")
        XCTAssertEqual(entry.timestamp, Date(timeIntervalSince1970: 1_777_320_000))

        let request = try XCTUnwrap(captured.value)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://api.au1.cliniko.com/v1/treatment_notes")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        // Pin that the wire body matches the request fixture (the
        // committed golden), so a future encoder swap that re-orders
        // fields or skips nulls fails this test rather than silently
        // changing what Cliniko sees.
        let bodyData = TreatmentNoteExporterTests.readBody(from: request)
        let actual = try JSONDecoder().decode(TreatmentNotePayload.self, from: bodyData)
        let expectedFixture = try HTTPStubFixture.load("cliniko/requests/treatment_notes_create.json")
        let expected = try JSONDecoder().decode(TreatmentNotePayload.self, from: expectedFixture)
        XCTAssertEqual(actual, expected)
    }

    /// Issue #58 — the audit ledger must reflect the actual HTTP status the
    /// server returned, not a documented constant. Today Cliniko documents
    /// 201 for `POST /treatment_notes`; if a future endpoint variant returns
    /// a different 2xx (e.g. 200 for the same logical create, or a 202 for a
    /// queued processing model), the audit row would lie under the old
    /// hardcoded literal. This test would have failed against the previous
    /// `clinikoStatus: 201` hardcoding.
    ///
    /// Lives alongside its XCTest siblings for cohesion with the rest of
    /// the exporter behaviour tests. (The historical motivation was a
    /// `URLProtocolStub` cross-suite race; #87 fixed that with
    /// per-installation dispatch, so this test could move to Swift Testing
    /// without races — kept here only because the surrounding sibs haven't
    /// migrated yet.)
    func test_export_audit_clinikoStatus_reflectsActualHTTPStatus_not201Literal() async throws {
        let session = makeSession { request in
            let body = Data("{\"id\":42}".utf8)
            // Stub 200 (not 201) to prove the exporter threads the
            // observed status — would mis-record as 201 under the old
            // hardcoded path.
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }
        let auditStore = InMemoryAuditStore()
        let exporter = makeExporter(session: session, auditStore: auditStore)

        let outcome = try await exporter.export(notes: makeNotes(), patientID: 1001, appointmentID: nil)

        XCTAssertEqual(outcome.created.id, 42)
        XCTAssertTrue(outcome.auditPersisted)
        let audit = try await auditStore.loadAll()
        XCTAssertEqual(audit.count, 1)
        XCTAssertEqual(try XCTUnwrap(audit.first).clinikoStatus, 200)
    }

    func test_export_201_withoutAppointmentID_recordsNilAppointment() async throws {
        let session = makeSession { request in
            let body = Data("{\"id\":42}".utf8)
            let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }
        let auditStore = InMemoryAuditStore()
        let exporter = makeExporter(session: session, auditStore: auditStore)

        let outcome = try await exporter.export(
            notes: makeNotes(),
            patientID: 1001,
            appointmentID: nil
        )

        XCTAssertEqual(outcome.created.id, 42)
        XCTAssertTrue(outcome.auditPersisted)

        let audit = try await auditStore.loadAll()
        XCTAssertEqual(audit.count, 1)
        XCTAssertNil(try XCTUnwrap(audit.first).appointmentID)
    }

    // MARK: - Audit-write failure must not look like an export failure

    func test_export_201_butAuditWriteFails_returnsAuditPersistedFalse_andDoesNotThrow() async throws {
        struct AuditWriteFailure: Error {}
        let session = makeSession { request in
            let body = Data("{\"id\":42}".utf8)
            let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }
        // Audit hook always throws — simulates "POST landed, audit
        // write failed" (full disk, perms revoked, etc.). The exporter
        // must NOT propagate this failure, otherwise the practitioner
        // would re-submit and double-write the clinical record.
        let auditStore = InMemoryAuditStore { _ in throw AuditWriteFailure() }
        let exporter = makeExporter(session: session, auditStore: auditStore)

        let outcome = try await exporter.export(notes: makeNotes(), patientID: 1001, appointmentID: nil)

        XCTAssertEqual(outcome.created.id, 42, "POST succeeded — created.id must surface")
        XCTAssertFalse(outcome.auditPersisted, "audit-write failed — caller must see auditPersisted=false")
        let audit = try await auditStore.loadAll()
        XCTAssertTrue(audit.isEmpty, "the failing hook prevented append — verify nothing landed")
    }

    // MARK: - Stale manipulation IDs surface via outcome, not via the wire

    func test_export_staleManipulationIDs_areSurfacedViaOutcome_notInBody() async throws {
        let captured = CapturedRequest()
        let session = makeSession { request in
            captured.set(request)
            let body = Data("{\"id\":42}".utf8)
            let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }
        let auditStore = InMemoryAuditStore()
        let exporter = makeExporter(session: session, auditStore: auditStore)

        let staleNotes = StructuredNotes(
            subjective: "ok",
            selectedManipulationIDs: ["diversified_hvla", "deleted_after_taxonomy_swap"]
        )
        let outcome = try await exporter.export(notes: staleNotes, patientID: 1001, appointmentID: nil)

        XCTAssertEqual(outcome.droppedManipulationIDs, ["deleted_after_taxonomy_swap"])
        // The stale ID must not have leaked into the wire body —
        // Cliniko sees only the resolved manipulations.
        let request = try XCTUnwrap(captured.value)
        let bodyData = TreatmentNoteExporterTests.readBody(from: request)
        let bodyText = try XCTUnwrap(String(data: bodyData, encoding: .utf8))
        XCTAssertFalse(bodyText.contains("deleted_after_taxonomy_swap"))
    }

    // MARK: - Error surfaces (audit must NOT be written)

    func test_export_401_throwsUnauthenticated_andDoesNotAudit() async throws {
        let counter = CallCounter()
        let session = makeSession { request in
            counter.increment()
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let auditStore = InMemoryAuditStore()
        let exporter = makeExporter(session: session, auditStore: auditStore)

        await assertExport(exporter: exporter, throws: .unauthenticated)
        let audit = try await auditStore.loadAll()
        XCTAssertTrue(audit.isEmpty, "401 must not produce an audit row")
        XCTAssertEqual(counter.value, 1, "401 must not trigger any retry")
    }

    func test_export_500_throwsServer_doesNotAutoRetry_andDoesNotAudit() async throws {
        let counter = CallCounter()
        let session = makeSession { request in
            counter.increment()
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let auditStore = InMemoryAuditStore()
        let exporter = makeExporter(session: session, auditStore: auditStore)

        await assertExport(exporter: exporter, throws: .server(status: 500))
        let audit = try await auditStore.loadAll()
        XCTAssertTrue(audit.isEmpty, "5xx must not produce an audit row")
        XCTAssertEqual(counter.value, 1, "POST is non-idempotent — 5xx must not auto-retry")
    }

    func test_export_503_throwsServer_doesNotAutoRetry_andDoesNotAudit() async throws {
        let counter = CallCounter()
        let session = makeSession { request in
            counter.increment()
            let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let auditStore = InMemoryAuditStore()
        let exporter = makeExporter(session: session, auditStore: auditStore)

        await assertExport(exporter: exporter, throws: .server(status: 503))
        let audit = try await auditStore.loadAll()
        XCTAssertTrue(audit.isEmpty)
        XCTAssertEqual(counter.value, 1)
    }

    func test_export_422_throwsValidation_andDoesNotAudit() async throws {
        let body = Data(#"{"errors":{"notes":["can't be blank"]}}"#.utf8)
        let session = makeSession { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }
        let auditStore = InMemoryAuditStore()
        let exporter = makeExporter(session: session, auditStore: auditStore)

        do {
            _ = try await exporter.export(notes: makeNotes(), patientID: 1001, appointmentID: nil)
            XCTFail("expected ClinikoError.validation")
        } catch let ClinikoError.validation(fields) {
            XCTAssertEqual(fields["notes"], ["can't be blank"])
        } catch {
            XCTFail("got \(error)")
        }
        let audit = try await auditStore.loadAll()
        XCTAssertTrue(audit.isEmpty)
    }

    func test_export_transportError_doesNotAutoRetry_andDoesNotAudit() async throws {
        let counter = CallCounter()
        let session = makeSession { _ in
            counter.increment()
            throw URLError(.notConnectedToInternet)
        }
        let auditStore = InMemoryAuditStore()
        let exporter = makeExporter(session: session, auditStore: auditStore)

        await assertExport(exporter: exporter, throws: .transport(.notConnectedToInternet))
        let audit = try await auditStore.loadAll()
        XCTAssertTrue(audit.isEmpty)
        XCTAssertEqual(counter.value, 1, "transport failure on POST must not auto-retry")
    }

    func test_export_201ButUndecodableBody_throwsResponseUndecodable_andDoesNotAudit() async throws {
        let session = makeSession { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
            return (response, Data("not json".utf8))
        }
        let auditStore = InMemoryAuditStore()
        let exporter = makeExporter(session: session, auditStore: auditStore)

        do {
            _ = try await exporter.export(notes: makeNotes(), patientID: 1001, appointmentID: nil)
            XCTFail("expected TreatmentNoteExporter.Failure.responseUndecodable")
        } catch TreatmentNoteExporter.Failure.responseUndecodable {
            // Distinct from `ClinikoError.decoding` so the UI in #14
            // can surface "the note may have landed; verify in
            // Cliniko before re-submitting" rather than offering a
            // one-tap retry that could double-write the record.
        } catch {
            XCTFail("got \(error)")
        }
        let audit = try await auditStore.loadAll()
        XCTAssertTrue(audit.isEmpty, "decode failure must not produce a (potentially mis-attributed) audit row")
    }

    // MARK: - Helpers

    private func assertExport(
        exporter: TreatmentNoteExporter,
        throws expected: ClinikoError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await exporter.export(notes: makeNotes(), patientID: 1001, appointmentID: nil)
            XCTFail("expected ClinikoError.\(expected)", file: file, line: line)
        } catch let error as ClinikoError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("got \(error) instead of ClinikoError.\(expected)", file: file, line: line)
        }
    }

    private static func readBody(from request: URLRequest) -> Data {
        if let direct = request.httpBody {
            return direct
        }
        guard let stream = request.httpBodyStream else {
            return Data()
        }
        var data = Data()
        stream.open()
        defer { stream.close() }
        let bufferSize = 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

// MARK: - Test helpers (mirror ClinikoClientTests.swift)

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    @discardableResult
    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return count
    }

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}

private final class CapturedRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: URLRequest?

    func set(_ request: URLRequest) {
        lock.lock(); defer { lock.unlock() }
        stored = request
    }

    var value: URLRequest? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}
