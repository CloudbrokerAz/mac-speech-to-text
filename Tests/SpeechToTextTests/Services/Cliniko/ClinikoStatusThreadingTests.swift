import Foundation
import Testing
@testable import SpeechToText

/// Pure-logic + async tests for the issue #58 contract:
/// `ClinikoClient.sendWithStatus(_:)` surfaces the actual 2xx HTTP status
/// the server returned, and `TreatmentNoteExporter.export(...)` writes that
/// observed status into the audit ledger row instead of a documented
/// constant. The legacy `send(_:)` forwarder must remain source-compatible
/// for callers (patient search, appointment list, `/users/me`) that don't
/// care about the status.
///
/// Lives in a Swift Testing `@Suite` per the project rule: new pure-logic
/// and async tests use `@Test` / `#expect` (see
/// `.claude/references/testing-conventions.md` and
/// `Tests/SpeechToTextTests/Utilities/SwiftTestingExemplarTests.swift`).
/// `URLProtocolStub` cleanup is RAII via `installScoped(_:)` rather than
/// an XCTest `tearDown` block.
///
/// `.serialized` is required: `URLProtocolStub` is a process-wide singleton
/// (one global `currentResponder`), and Swift Testing runs tests within a
/// suite in parallel by default. Without serialization two tests installing
/// different responders concurrently would clobber each other and one would
/// see the other's stubbed body.
@Suite("Cliniko HTTP-status threading (#58)", .tags(.fast), .serialized)
struct ClinikoStatusThreadingTests {

    // MARK: - Helpers

    private static var credentials: ClinikoCredentials {
        // swiftlint:disable:next force_try
        try! ClinikoCredentials(apiKey: "MS-test-au1", shard: .au1)
    }

    private static func makeClient(session: URLSession) -> ClinikoClient {
        ClinikoClient(
            credentials: credentials,
            session: session,
            userAgent: "status-threading-tests/1.0",
            retryPolicy: .immediate
        )
    }

    private struct UsersMeResponse: Decodable, Sendable, Equatable {
        let id: Int
        let firstName: String
        let lastName: String
        let email: String
    }

    private struct CreatedID: Decodable, Sendable, Equatable {
        let id: Int
    }

    // MARK: - sendWithStatus surfaces the actual 2xx

    /// 200 — the documented status for `/users/me`. Pins that
    /// `sendWithStatus` returns the *observed* status alongside the body.
    @Test("sendWithStatus surfaces 200 from a successful GET")
    func sendWithStatus_returns200_fromUsersMe() async throws {
        let installation = URLProtocolStub.installScoped { request in
            let body = try HTTPStubFixture.load("cliniko/responses/users_me.json")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, body)
        }
        let session = URLSession(configuration: installation.configuration)
        let client = Self.makeClient(session: session)

        let (user, status): (UsersMeResponse, Int) = try await client.sendWithStatus(.usersMe)

        #expect(status == 200)
        #expect(user.id == 12345)
    }

    /// 201 — the documented status for `POST /treatment_notes`. Pins the
    /// other side of the contract: a regression that hardcoded `200`
    /// somewhere in the success path would fail this test.
    @Test("sendWithStatus surfaces 201 from a successful POST")
    func sendWithStatus_returns201_fromCreateTreatmentNote() async throws {
        let installation = URLProtocolStub.installScoped { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 201,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data("{\"id\":42}".utf8))
        }
        let session = URLSession(configuration: installation.configuration)
        let client = Self.makeClient(session: session)

        let (created, status): (CreatedID, Int) = try await client.sendWithStatus(
            .createTreatmentNote(body: Data("{}".utf8))
        )

        #expect(status == 201)
        #expect(created.id == 42)
    }

    /// `send(_:)` is now a thin forwarder over `sendWithStatus(_:)`. Pin
    /// that it still decodes a bare value — call sites that opt out of the
    /// tuple shouldn't get a different value than they did before #58.
    @Test("send(_:) forwarder still returns a bare decoded value")
    func send_forwarder_stillDecodesBody_whenCallerIgnoresStatus() async throws {
        let installation = URLProtocolStub.installScoped { request in
            let body = try HTTPStubFixture.load("cliniko/responses/users_me.json")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, body)
        }
        let session = URLSession(configuration: installation.configuration)
        let client = Self.makeClient(session: session)

        let user: UsersMeResponse = try await client.send(.usersMe)

        #expect(user.id == 12345)
    }

    // MARK: - Exporter writes the observed status into the audit row

    /// The audit ledger must reflect the actual HTTP status the server
    /// returned, not the hardcoded `201` that lived in
    /// `TreatmentNoteExporter.export(...)` before #58. Today Cliniko
    /// documents 201 for `POST /treatment_notes`; if a future endpoint
    /// variant returns a different 2xx (e.g. 200, or 202 from a queued
    /// processing model) the audit row would lie under the old literal.
    /// Stubbing 200 here would have failed against the previous
    /// `clinikoStatus: 201` hardcoding — this is the regression pin.
    @Test("Exporter audit row reflects the observed HTTP status, not a constant")
    func exporter_auditRow_reflectsActualStatus_not201Literal() async throws {
        let installation = URLProtocolStub.installScoped { request in
            let body = Data("{\"id\":42}".utf8)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }
        let session = URLSession(configuration: installation.configuration)
        let client = ClinikoClient(
            credentials: Self.credentials,
            session: session,
            userAgent: "exporter-status-tests/1.0",
            retryPolicy: .immediate
        )
        let auditStore = InMemoryAuditStore()
        let exporter = TreatmentNoteExporter(
            client: client,
            auditStore: auditStore,
            manipulations: ManipulationsRepository(all: [
                Manipulation(id: "diversified_hvla", displayName: "Diversified HVLA", clinikoCode: nil)
            ]),
            appVersion: "0.3.0-test",
            now: { Date(timeIntervalSince1970: 1_777_320_000) }
        )

        let notes = StructuredNotes(
            subjective: "Patient reports lower-back pain after gardening.",
            objective: "ROM reduced; tender at L4-L5.",
            assessment: "Mechanical low back pain.",
            plan: "Diversified HVLA + home stretching plan.",
            selectedManipulationIDs: ["diversified_hvla"]
        )
        let outcome = try await exporter.export(
            notes: notes,
            patientID: 1001,
            appointmentID: nil
        )

        #expect(outcome.created.id == 42)
        #expect(outcome.auditPersisted)

        let audit = try await auditStore.loadAll()
        #expect(audit.count == 1)
        let entry = try #require(audit.first)
        #expect(entry.clinikoStatus == 200, "exporter must thread the observed 200, not the previous hardcoded 201")
    }

    /// Belt-and-braces: the documented 201 path also lands as 201 on the
    /// audit row. Catches a regression where a future change might
    /// accidentally swap the threaded status for some other 2xx default.
    @Test("Exporter audit row records 201 when Cliniko returns 201")
    func exporter_auditRow_records201_whenServerReturns201() async throws {
        let installation = URLProtocolStub.installScoped { request in
            let body = Data("{\"id\":99}".utf8)
            let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }
        let session = URLSession(configuration: installation.configuration)
        let client = ClinikoClient(
            credentials: Self.credentials,
            session: session,
            userAgent: "exporter-status-tests/1.0",
            retryPolicy: .immediate
        )
        let auditStore = InMemoryAuditStore()
        let exporter = TreatmentNoteExporter(
            client: client,
            auditStore: auditStore,
            manipulations: ManipulationsRepository(all: []),
            appVersion: "0.3.0-test",
            now: { Date(timeIntervalSince1970: 1_777_320_000) }
        )

        let outcome = try await exporter.export(
            notes: StructuredNotes(subjective: "ok"),
            patientID: 1001,
            appointmentID: nil
        )

        #expect(outcome.created.id == 99)
        let audit = try await auditStore.loadAll()
        let entry = try #require(audit.first)
        #expect(entry.clinikoStatus == 201)
    }
}
