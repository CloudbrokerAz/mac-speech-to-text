// ExportFlowCoordinatorTests.swift
// macOS Local Speech-to-Text Application
//
// Direct coverage for `ExportFlowCoordinator` (#251 / TST-4). Pins the
// coordinator-owned contracts that `ExportFlowViewModelTests` only
// exercises incidentally:
//   - session cleared only on a successful export (via the wired
//     `onSuccess` closure)
//   - audit ledger receives metadata-only rows on success
//   - failed exports leave the session intact and write no audit row
//
// Uses `InMemoryAuditStore` + `URLProtocolStub` per
// `.claude/references/testing-conventions.md`.

import Foundation
import Testing
@testable import SpeechToText

@Suite("ExportFlowCoordinator", .tags(.fast))
@MainActor
struct ExportFlowCoordinatorTests {

    /// Allowed JSON keys per `.claude/references/cliniko-api.md` §Audit.
    private static let auditAllowedKeys: Set<String> = [
        "timestamp",
        "patient_id",
        "appointment_id",
        "note_id",
        "cliniko_status",
        "app_version"
    ]

    /// Keys that must never appear in an audit row — if any of these
    /// surface, SOAP / transcript PHI has leaked into the ledger.
    private static let forbiddenAuditKeys: Set<String> = [
        "subjective",
        "objective",
        "assessment",
        "plan",
        "notes",
        "body",
        "transcript",
        "patient_name",
        "content"
    ]

    // MARK: - Helpers

    private func stubManipulations() -> ManipulationsRepository {
        ManipulationsRepository(all: [
            Manipulation(id: "diversified_hvla", displayName: "Diversified HVLA", clinikoCode: nil)
        ])
    }

    private func makePopulatedSession() -> SessionStore {
        let store = SessionStore()
        var recording = RecordingSession(language: "en", state: .completed)
        recording.transcribedText = "Synthetic transcript for coordinator test."
        store.start(from: recording)
        store.setDraftNotes(StructuredNotes(
            subjective: "Synthetic subjective.",
            objective: "Synthetic objective.",
            assessment: "Synthetic assessment.",
            plan: "Synthetic plan.",
            selectedManipulationIDs: ["diversified_hvla"]
        ))
        store.setSelectedPatient(id: OpaqueClinikoID(1001), displayName: "Sample Patient")
        store.setSelectedAppointment(id: OpaqueClinikoID(5001))
        return store
    }

    private func makeExporter(
        config: URLSessionConfiguration,
        auditStore: any AuditStore
    ) -> TreatmentNoteExporter {
        let session = URLSession(configuration: config)
        // swiftlint:disable:next force_try
        let creds = try! ClinikoCredentials(apiKey: "MS-test-au1", shard: .au1)
        let client = ClinikoClient(
            credentials: creds,
            session: session,
            userAgent: "coordinator-tests/1.0",
            retryPolicy: .immediate
        )
        return TreatmentNoteExporter(
            client: client,
            auditStore: auditStore,
            manipulations: stubManipulations(),
            appVersion: "0.0.0-coordinator-test"
        )
    }

    private func configureCoordinator(
        sessionStore: SessionStore,
        exporter: TreatmentNoteExporter,
        closeReviewWindow: @escaping () -> Void = {}
    ) {
        ExportFlowCoordinator.shared.configure(
            sessionStore: sessionStore,
            exporter: exporter,
            manipulations: stubManipulations(),
            openClinikoSettings: {},
            closeReviewWindow: closeReviewWindow
        )
    }

    private func runGated(
        responder: @escaping URLProtocolStub.Responder,
        body: @MainActor @Sendable (URLSessionConfiguration) async throws -> Void
    ) async throws {
        try await URLProtocolStubGate.shared.withGate {
            let config = URLProtocolStub.install(responder)
            defer { URLProtocolStub.reset() }
            try await body(config)
        }
    }

    private func waitForTerminal(
        _ viewModel: ExportFlowViewModel,
        timeout: TimeInterval = 5.0,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        polling: while true {
            switch viewModel.state {
            case .failed, .succeeded:
                return
            default:
                if Date() >= deadline { break polling }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        switch viewModel.state {
        case .failed, .succeeded:
            return
        default:
            Issue.record(
                "waitForTerminal timed out after \(timeout)s",
                sourceLocation: sourceLocation
            )
        }
    }

    private func assertAuditMetadataOnly(_ record: AuditRecord) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let keys = Set(json.keys)

        #expect(keys.isSubset(of: Self.auditAllowedKeys))
        #expect(Self.auditAllowedKeys.isSubset(of: keys))
        #expect(keys.isDisjoint(with: Self.forbiddenAuditKeys))

        // Structural IDs only — no free-text clinical content fields.
        #expect(json["patient_id"] is String)
        #expect(json["note_id"] is String)
        #expect(json["cliniko_status"] is Int)
        #expect(json["app_version"] is String)
    }

    // MARK: - Success path

    @Test("Successful export clears the session and records metadata-only audit")
    func success_clearsSession_andRecordsMetadataOnlyAudit() async throws {
        try await runGated(responder: { request in
            let body = try HTTPStubFixture.load("cliniko/responses/treatment_notes_create.json")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 201,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, body)
        }) { config in
            let store = self.makePopulatedSession()
            let auditStore = InMemoryAuditStore()
            let exporter = self.makeExporter(config: config, auditStore: auditStore)
            var closedReviewWindow = false
            self.configureCoordinator(
                sessionStore: store,
                exporter: exporter,
                closeReviewWindow: { closedReviewWindow = true }
            )

            guard let viewModel = ExportFlowCoordinator.shared.makeViewModel() else {
                Issue.record("coordinator not configured")
                return
            }

            viewModel.enterConfirming()
            viewModel.confirm()
            try await self.waitForTerminal(viewModel)

            guard case .succeeded = viewModel.state else {
                Issue.record("expected .succeeded")
                return
            }

            #expect(store.active == nil, "session must be cleared on success")
            #expect(closedReviewWindow, "closeReviewWindow fires on success")

            let audit = try await auditStore.loadAll()
            #expect(audit.count == 1)
            try self.assertAuditMetadataOnly(try #require(audit.first))
            #expect(audit.first?.patientID == OpaqueClinikoID(1001))
            #expect(audit.first?.appointmentID == OpaqueClinikoID(5001))
            #expect(audit.first?.noteID == OpaqueClinikoID(9876543))
            #expect(audit.first?.clinikoStatus == 201)
        }
    }

    // MARK: - Failure path

    @Test("Failed export leaves the session intact and writes no audit row")
    func failure_preservesSession_andWritesNoAudit() async throws {
        try await runGated(responder: { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }) { config in
            let store = self.makePopulatedSession()
            let auditStore = InMemoryAuditStore()
            let exporter = self.makeExporter(config: config, auditStore: auditStore)
            var closedReviewWindow = false
            self.configureCoordinator(
                sessionStore: store,
                exporter: exporter,
                closeReviewWindow: { closedReviewWindow = true }
            )

            guard let viewModel = ExportFlowCoordinator.shared.makeViewModel() else {
                Issue.record("coordinator not configured")
                return
            }

            viewModel.enterConfirming()
            viewModel.confirm()
            try await self.waitForTerminal(viewModel)

            guard case .failed = viewModel.state else {
                Issue.record("expected .failed")
                return
            }

            #expect(store.active != nil, "session must survive a failed export")
            #expect(!closedReviewWindow, "closeReviewWindow must not fire on failure")

            let audit = try await auditStore.loadAll()
            #expect(audit.isEmpty)
        }
    }
}
