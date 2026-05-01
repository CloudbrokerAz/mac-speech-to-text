import Foundation
import Testing
@testable import SpeechToText

/// Issue #58 contract tests — the actual HTTP status the server
/// returned must thread through `ClinikoClient.sendWithStatus(_:)`
/// to `TreatmentNoteExporter` so the audit ledger reflects what
/// happened, not a documented constant.
///
/// These four tests originally landed in PR #84 as a Swift Testing
/// suite, but had to be reverted to XCTest siblings because two
/// Swift Testing suites that both stub HTTP raced against each other
/// across the suite boundary (`ModelDownloaderTests` vs this file).
/// Issue #85 introduces `URLProtocolStubGate` to serialise stub
/// installs process-wide; with the gate adopted the migration is
/// safe. See `.claude/references/testing-conventions.md`
/// §"URLProtocolStub process-wide gate" and PR #84 review for the
/// full history.
@Suite("Cliniko status threading", .tags(.fast))
struct ClinikoStatusThreadingTests {

    // MARK: - Helpers

    /// Hand-rolled "current `URLRequest`" recorder. The responder
    /// closure is `@Sendable` so a plain `var` won't suffice; an
    /// actor-backed implementation would force every read site to
    /// `await`, which is unnecessary here because the responder fires
    /// once per request.
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

    private struct UsersMeResponse: Decodable, Sendable, Equatable {
        let id: Int
        let firstName: String
        let lastName: String
        let email: String
    }

    private static func makeCredentials() throws -> ClinikoCredentials {
        try ClinikoCredentials(apiKey: "MS-test-au1", shard: .au1)
    }

    private static func makeClient(
        session: URLSession,
        retryPolicy: ClinikoClient.RetryPolicy = .immediate
    ) throws -> ClinikoClient {
        ClinikoClient(
            credentials: try makeCredentials(),
            session: session,
            userAgent: "status-threading-tests/1.0",
            retryPolicy: retryPolicy
        )
    }

    private static func makeManipulations() -> ManipulationsRepository {
        ManipulationsRepository(all: [
            Manipulation(id: "diversified_hvla", displayName: "Diversified HVLA", clinikoCode: nil),
            Manipulation(id: "drop_table", displayName: "Drop-Table Technique", clinikoCode: nil)
        ])
    }

    private static func makeNotes() -> StructuredNotes {
        StructuredNotes(
            subjective: "Patient reports lower-back pain after gardening.",
            objective: "ROM reduced; tender at L4-L5.",
            assessment: "Mechanical low back pain.",
            plan: "Diversified HVLA + home stretching plan.",
            selectedManipulationIDs: ["diversified_hvla", "drop_table"]
        )
    }

    // MARK: - sendWithStatus surfaces the actual 2xx code (#58)

    /// Pin that `sendWithStatus(_:)` returns the observed HTTP status
    /// alongside the decoded body. The audit ledger row consumes this;
    /// the contract is on the client itself so any 2xx is success and
    /// the *specific* 2xx code reaches the caller rather than being
    /// smashed to a documented constant.
    @Test("sendWithStatus_returnsActualStatusFromResponse")
    func sendWithStatus_returnsActualStatusFromResponse() async throws {
        try await URLProtocolStubGate.shared.withGate {
            let config = URLProtocolStub.install { request in
                let body = try HTTPStubFixture.load("cliniko/responses/user.json")
                // 200 — the documented status for /user.
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, body)
            }
            defer { URLProtocolStub.reset() }
            let session = URLSession(configuration: config)
            let client = try Self.makeClient(session: session)

            let (user, status): (UsersMeResponse, Int) = try await client.sendWithStatus(.usersMe)

            #expect(status == 200)
            #expect(user.id == 12345)
        }
    }

    /// Pin the 201 path too so the exporter's audit row always reflects
    /// the real status — would catch a regression that hardcoded `200`
    /// somewhere in the success path.
    @Test("sendWithStatus_returns201_fromCreateTreatmentNote")
    func sendWithStatus_returns201_fromCreateTreatmentNote() async throws {
        try await URLProtocolStubGate.shared.withGate {
            let config = URLProtocolStub.install { request in
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 201,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data("{\"id\":42}".utf8))
            }
            defer { URLProtocolStub.reset() }
            let session = URLSession(configuration: config)
            let client = try Self.makeClient(session: session)

            struct CreatedID: Decodable, Sendable, Equatable { let id: Int }
            let (created, status): (CreatedID, Int) = try await client.sendWithStatus(
                .createTreatmentNote(body: Data("{}".utf8))
            )

            #expect(status == 201)
            #expect(created.id == 42)
        }
    }

    /// `send(_:)` is now a thin forwarder over `sendWithStatus(_:)`.
    /// Pin that it still drops the status cleanly — call sites that
    /// opt out of the tuple shouldn't get a different value than they
    /// did before.
    @Test("send_stillDecodesBody_whenCallerIgnoresStatus")
    func send_stillDecodesBody_whenCallerIgnoresStatus() async throws {
        try await URLProtocolStubGate.shared.withGate {
            let config = URLProtocolStub.install { request in
                let body = try HTTPStubFixture.load("cliniko/responses/user.json")
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, body)
            }
            defer { URLProtocolStub.reset() }
            let session = URLSession(configuration: config)
            let client = try Self.makeClient(session: session)

            let user: UsersMeResponse = try await client.send(.usersMe)
            #expect(user.id == 12345)
        }
    }

    // MARK: - Exporter audit row reflects observed status

    /// The audit ledger must reflect the actual HTTP status the server
    /// returned, not a documented constant. Today Cliniko documents 201
    /// for `POST /treatment_notes`; if a future endpoint variant returns
    /// a different 2xx (e.g. 200 for the same logical create, or a 202
    /// for a queued processing model), the audit row would lie under
    /// the previous hardcoded literal. This test would have failed
    /// against the pre-#58 `clinikoStatus: 201` hardcoding.
    @Test("export_audit_clinikoStatus_reflectsActualHTTPStatus_not201Literal")
    func export_audit_clinikoStatus_reflectsActualHTTPStatus_not201Literal() async throws {
        try await URLProtocolStubGate.shared.withGate {
            let config = URLProtocolStub.install { request in
                let body = Data("{\"id\":42}".utf8)
                // Stub 200 (not 201) to prove the exporter threads the
                // observed status — would mis-record as 201 under the old
                // hardcoded path.
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (response, body)
            }
            defer { URLProtocolStub.reset() }
            let session = URLSession(configuration: config)
            let client = try Self.makeClient(session: session)
            let auditStore = InMemoryAuditStore()
            let exporter = TreatmentNoteExporter(
                client: client,
                auditStore: auditStore,
                manipulations: Self.makeManipulations(),
                appVersion: "0.3.0-test",
                now: { Date(timeIntervalSince1970: 1_777_320_000) }
            )

            let outcome = try await exporter.export(
                notes: Self.makeNotes(),
                patientID: 1001,
                appointmentID: nil
            )

            #expect(outcome.created.id == 42)
            #expect(outcome.auditPersisted)
            let audit = try await auditStore.loadAll()
            #expect(audit.count == 1)
            #expect(audit.first?.clinikoStatus == 200)
        }
    }
}
