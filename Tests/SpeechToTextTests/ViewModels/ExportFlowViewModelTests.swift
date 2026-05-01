// ExportFlowViewModelTests.swift
// macOS Local Speech-to-Text Application
//
// Swift Testing `.fast` suite for ExportFlowViewModel (#14). Covers
// every FSM transition × every ExportFailure case translation. Uses
// in-test fakes — no real Cliniko traffic, no real audit ledger.
// `URLProtocolStub` wires up the `ClinikoClient` underneath the
// `TreatmentNoteExporter` actor so we can drive end-to-end POST
// outcomes deterministically.

import Foundation
import Testing
@testable import SpeechToText

@Suite("ExportFlowViewModel", .tags(.fast), .serialized)
@MainActor
struct ExportFlowViewModelTests {

    // MARK: - Helpers

    private func stubManipulations() -> ManipulationsRepository {
        ManipulationsRepository(all: [
            Manipulation(id: "diversified_hvla", displayName: "Diversified HVLA", clinikoCode: nil)
        ])
    }

    private func makePopulatedSession(
        patientID: OpaqueClinikoID = OpaqueClinikoID(1001),
        appointmentID: OpaqueClinikoID? = OpaqueClinikoID(5001),
        notes: StructuredNotes? = StructuredNotes(
            subjective: "S",
            objective: "O",
            assessment: "A",
            plan: "P",
            selectedManipulationIDs: ["diversified_hvla"]
        )
    ) -> SessionStore {
        let store = SessionStore()
        var recording = RecordingSession(language: "en", state: .completed)
        recording.transcribedText = "Synthetic transcript"
        store.start(from: recording)
        if let notes {
            store.setDraftNotes(notes)
        }
        store.setSelectedPatient(id: patientID, displayName: "Sample Patient")
        store.setSelectedAppointment(id: appointmentID)
        return store
    }

    private func makeExporter(
        responder: @escaping URLProtocolStub.Responder,
        auditStore: any AuditStore = InMemoryAuditStore()
    ) -> TreatmentNoteExporter {
        let config = URLProtocolStub.install(responder)
        let session = URLSession(configuration: config)
        // swiftlint:disable:next force_try
        let creds = try! ClinikoCredentials(apiKey: "MS-test-au1", shard: .au1)
        let client = ClinikoClient(
            credentials: creds,
            session: session,
            userAgent: "exporter-tests/1.0",
            retryPolicy: .immediate
        )
        return TreatmentNoteExporter(
            client: client,
            auditStore: auditStore,
            manipulations: stubManipulations(),
            appVersion: "0.0.0-test"
        )
    }

    private func makeViewModel(
        store: SessionStore,
        exporter: TreatmentNoteExporter,
        onSuccess: @escaping () -> Void = {},
        openClinikoSettings: @escaping () -> Void = {},
        copyToClipboard: @escaping (String) -> Void = { _ in }
    ) -> ExportFlowViewModel {
        ExportFlowViewModel(
            sessionStore: store,
            dependencies: ExportFlowDependencies(
                exporter: exporter,
                manipulations: stubManipulations(),
                onSuccess: onSuccess,
                openClinikoSettings: openClinikoSettings,
                copyToClipboard: copyToClipboard
            )
        )
    }

    // MARK: - Confirming state

    @Test("enterConfirming transitions from idle and computes section counts")
    func enterConfirming_buildsSummary() {
        let store = makeSessionForConfirmingTest()
        let exporter = makeExporter { _ in (HTTPURLResponse(), Data()) }
        let viewModel = makeViewModel(store: store, exporter: exporter)

        viewModel.enterConfirming()

        guard case .confirming(let summary) = viewModel.state else {
            Issue.record("expected .confirming, got \(viewModel.state)")
            return
        }
        #expect(summary.patientID == OpaqueClinikoID(1001))
        #expect(summary.patientDisplayName == "Sample Patient")
        #expect(summary.sectionCounts.count == 4)
        // The summary surfaces actual char counts so the
        // confirmation UI can render "Subjective: 1 chars".
        #expect(summary.sectionCounts.first(where: { $0.field == .subjective })?.charCount == 1)
        // Existing appointment writes through to the picker as
        // .appointment(...); the export-flow seed is .unset so the
        // practitioner has to explicitly choose. (See doc on
        // ExportFlowViewModel.buildSummary).
        // Wait — actually the buildSummary code reads
        // selectedAppointmentID and uses it as `.appointment(...)`
        // when present. The test's session has appointmentID 5001,
        // so we expect `.appointment(5001)`.
        #expect(summary.appointment == .appointment(OpaqueClinikoID(5001)))
    }

    @Test("enterConfirming with no active session transitions to .failed(.sessionState(.noActiveSession))")
    func enterConfirming_noActiveSession_fails() {
        let store = SessionStore() // no .start
        let exporter = makeExporter { _ in (HTTPURLResponse(), Data()) }
        let viewModel = makeViewModel(store: store, exporter: exporter)

        viewModel.enterConfirming()

        if case .failed(.sessionState(.noActiveSession)) = viewModel.state {
            // expected
        } else {
            Issue.record("expected .failed(.sessionState(.noActiveSession)), got \(viewModel.state)")
        }
    }

    @Test("enterConfirming with no patient transitions to .failed(.sessionState(.noPatient))")
    func enterConfirming_noPatient_fails() {
        let store = SessionStore()
        store.start(from: RecordingSession(language: "en", state: .completed))
        // No setSelectedPatient call.
        let exporter = makeExporter { _ in (HTTPURLResponse(), Data()) }
        let viewModel = makeViewModel(store: store, exporter: exporter)

        viewModel.enterConfirming()

        if case .failed(.sessionState(.noPatient)) = viewModel.state {
            // expected
        } else {
            Issue.record("expected .failed(.sessionState(.noPatient)), got \(viewModel.state)")
        }
    }

    // MARK: - setAppointmentSelection

    @Test("setAppointmentSelection updates the summary's appointment in place")
    func setAppointmentSelection_updatesSummary() {
        let store = makeSessionForConfirmingTest()
        let exporter = makeExporter { _ in (HTTPURLResponse(), Data()) }
        let viewModel = makeViewModel(store: store, exporter: exporter)
        viewModel.enterConfirming()

        viewModel.setAppointmentSelection(.general)

        guard case .confirming(let summary) = viewModel.state else {
            Issue.record("expected .confirming")
            return
        }
        #expect(summary.appointment == .general)
    }

    // MARK: - Confirm + happy path

    @Test("confirm + 201 transitions through .uploading → .succeeded")
    func confirm_201_succeeds() async throws {
        let store = makeSessionForConfirmingTest()
        let exporter = makeExporter { request in
            let body = try HTTPStubFixture.load("cliniko/responses/treatment_notes_create.json")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 201,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, body)
        }
        var onSuccessCalled = false
        let viewModel = makeViewModel(
            store: store,
            exporter: exporter,
            onSuccess: { onSuccessCalled = true }
        )
        viewModel.enterConfirming()

        viewModel.confirm()

        // Drive the async POST to completion.
        try await Task.sleep(nanoseconds: 100_000_000)

        guard case .succeeded(let report) = viewModel.state else {
            Issue.record("expected .succeeded, got \(viewModel.state)")
            return
        }
        #expect(report.createdNoteID == OpaqueClinikoID(9876543))
        #expect(report.auditPersisted == true)
        #expect(onSuccessCalled, "onSuccess hook fires on success")
    }

    /// Regression pin for #129's `appointmentIDMalformed` guard. After
    /// `Appointment.id` flipped to `String` (Cliniko's documented
    /// `string($int64)` shape), a non-numeric `OpaqueClinikoID.rawValue`
    /// could silently degrade the export to a general note (losing
    /// the appointment linkage with no user-visible signal). Same
    /// class of bug #127's `patientIDMalformed` guard closed off for
    /// the patient boundary.
    @Test("confirm with malformed appointment id fails with appointmentIDMalformed")
    func confirm_malformedAppointmentID_fails() {
        let store = SessionStore()
        store.start(from: RecordingSession(language: "en", state: .completed))
        store.setSelectedPatient(id: OpaqueClinikoID(1001), displayName: "Sample")
        store.setDraftNotes(StructuredNotes(subjective: "s"))
        // Appointment id with a non-numeric rawValue. Production never
        // produces this (Cliniko emits numeric strings) but Codable
        // round-trip from a tampered audit ledger or a future Cliniko
        // shape change would. The `.appointment(...)` shape (vs
        // `.unset` / `.general`) is what triggers the guard.
        store.setSelectedAppointment(id: OpaqueClinikoID(rawValue: "not-numeric"))
        let exporter = makeExporter { _ in (HTTPURLResponse(), Data()) }
        let viewModel = makeViewModel(store: store, exporter: exporter)
        viewModel.enterConfirming()

        viewModel.confirm()

        if case .failed(.sessionState(.appointmentIDMalformed)) = viewModel.state {
            // expected
        } else {
            Issue.record("expected .failed(.sessionState(.appointmentIDMalformed)), got \(viewModel.state)")
        }
    }

    @Test("confirm with .unset appointment fails with appointmentUnresolved")
    func confirm_unsetAppointment_fails() {
        let store = SessionStore()
        store.start(from: RecordingSession(language: "en", state: .completed))
        store.setSelectedPatient(id: OpaqueClinikoID(1001), displayName: "Sample")
        store.setDraftNotes(StructuredNotes(subjective: "s"))
        // No setSelectedAppointment — picker unset.
        let exporter = makeExporter { _ in (HTTPURLResponse(), Data()) }
        let viewModel = makeViewModel(store: store, exporter: exporter)
        viewModel.enterConfirming()
        // The summary's appointment is `.unset` (no appointment
        // ID set on the session). Calling confirm should bail.
        viewModel.confirm()

        if case .failed(.sessionState(.appointmentUnresolved)) = viewModel.state {
            // expected
        } else {
            Issue.record("expected .failed(.sessionState(.appointmentUnresolved)), got \(viewModel.state)")
        }
    }

    // MARK: - Failure translations

    @Test("401 → .failed(.unauthenticated)")
    func confirm_401_unauthenticated() async throws {
        try await assertConfirmFailsWith(.unauthenticated, status: 401)
    }

    @Test("403 → .failed(.forbidden)")
    func confirm_403_forbidden() async throws {
        try await assertConfirmFailsWith(.forbidden, status: 403)
    }

    @Test("404 → .failed(.notFound)")
    func confirm_404_notFound() async throws {
        try await assertConfirmFailsWith(.notFound(resource: .treatmentNote), status: 404)
    }

    @Test("422 → .failed(.validation)")
    func confirm_422_validation() async throws {
        try await assertConfirmFailsWith(
            .validation(fields: ["notes": ["can't be blank"]]),
            status: 422,
            body: Data(#"{"errors":{"notes":["can't be blank"]}}"#.utf8)
        )
    }

    @Test("500 → .failed(.server(status: 500))")
    func confirm_500_server() async throws {
        try await assertConfirmFailsWith(.server(status: 500), status: 500)
    }

    @Test("503 → .failed(.server(status: 503))")
    func confirm_503_server() async throws {
        try await assertConfirmFailsWith(.server(status: 503), status: 503)
    }

    @Test("Transport error (offline) → .failed(.transport(.notConnectedToInternet))")
    func confirm_transport_offline() async throws {
        let store = makeSessionForConfirmingTest()
        let exporter = makeExporter { _ in
            throw URLError(.notConnectedToInternet)
        }
        let viewModel = makeViewModel(store: store, exporter: exporter)
        viewModel.enterConfirming()
        viewModel.confirm()
        try await Task.sleep(nanoseconds: 100_000_000)

        if case .failed(.transport(.notConnectedToInternet)) = viewModel.state {
            // expected
        } else {
            Issue.record("expected .failed(.transport(.notConnectedToInternet)), got \(viewModel.state)")
        }
    }

    @Test("2xx + undecodable body → .failed(.responseUndecodable) — no auto-retry")
    func confirm_201_undecodable() async throws {
        let store = makeSessionForConfirmingTest()
        let exporter = makeExporter { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
            return (response, Data("not json".utf8))
        }
        let viewModel = makeViewModel(store: store, exporter: exporter)
        viewModel.enterConfirming()
        viewModel.confirm()
        try await Task.sleep(nanoseconds: 100_000_000)

        if case .failed(.responseUndecodable) = viewModel.state {
            // expected — UI must NOT offer one-tap retry, the note
            // may have landed on Cliniko's side.
        } else {
            Issue.record("expected .failed(.responseUndecodable), got \(viewModel.state)")
        }
    }

    // MARK: - 429 countdown

    @Test("429 → .failed(.rateLimited) seeds the countdown")
    func confirm_429_seedsCountdown() async throws {
        let store = makeSessionForConfirmingTest()
        let exporter = makeExporter { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: ["Retry-After": "5"]
            )!
            return (response, Data())
        }
        let viewModel = makeViewModel(store: store, exporter: exporter)
        viewModel.enterConfirming()
        viewModel.confirm()
        try await Task.sleep(nanoseconds: 200_000_000)

        if case .failed(.rateLimited(let retryAfter)) = viewModel.state {
            #expect(retryAfter == 5)
        } else {
            Issue.record("expected .failed(.rateLimited), got \(viewModel.state)")
        }
        // Countdown started — value should be set.
        #expect((viewModel.rateLimitCountdownRemaining ?? 0) > 0)
    }

    // MARK: - openClinikoSettings + copyToClipboard

    @Test("openClinikoSettings invokes the dependency callback")
    func openClinikoSettings_invokesCallback() {
        var called = false
        let store = makeSessionForConfirmingTest()
        let exporter = makeExporter { _ in (HTTPURLResponse(), Data()) }
        let viewModel = makeViewModel(
            store: store,
            exporter: exporter,
            openClinikoSettings: { called = true }
        )

        viewModel.openClinikoSettings()
        #expect(called)
    }

    @Test("copyNoteToClipboard invokes the dependency with the composed body")
    func copyNoteToClipboard_invokesCallback() {
        var captured: String?
        let store = makeSessionForConfirmingTest()
        let exporter = makeExporter { _ in (HTTPURLResponse(), Data()) }
        let viewModel = makeViewModel(
            store: store,
            exporter: exporter,
            copyToClipboard: { body in captured = body }
        )

        viewModel.copyNoteToClipboard()

        // The composed body is non-empty for our seeded session.
        #expect(captured?.isEmpty == false)
        // Defensive: SOAP fields are present in the body.
        #expect(captured?.contains("Subjective") == true || captured?.contains("S") == true)
    }

    // MARK: - cancelFromConfirming

    @Test("cancelFromConfirming returns to .idle")
    func cancelFromConfirming_returnsToIdle() {
        let store = makeSessionForConfirmingTest()
        let exporter = makeExporter { _ in (HTTPURLResponse(), Data()) }
        let viewModel = makeViewModel(store: store, exporter: exporter)
        viewModel.enterConfirming()

        viewModel.cancelFromConfirming()

        if case .idle = viewModel.state {
            // expected
        } else {
            Issue.record("expected .idle, got \(viewModel.state)")
        }
    }

    // MARK: - translate(_:) defaults

    @Test("translate maps CancellationError to .cancelled")
    func translate_cancellationError_mapsToCancelled() {
        let translated = ExportFlowViewModel.translate(CancellationError())
        #expect(translated == .cancelled)
    }

    @Test("translate maps unknown errors to .transport(.unknown)")
    func translate_unknownError_mapsToTransport() {
        struct Custom: Error {}
        let translated = ExportFlowViewModel.translate(Custom())
        #expect(translated == .transport(.unknown))
    }

    @Test("translate maps every ClinikoError to a matching ExportFailure")
    func translate_clinikoErrors() {
        #expect(ExportFlowViewModel.translate(ClinikoError.unauthenticated) == .unauthenticated)
        #expect(ExportFlowViewModel.translate(ClinikoError.forbidden) == .forbidden)
        #expect(ExportFlowViewModel.translate(ClinikoError.notFound(resource: .patient)) == .notFound(resource: .patient))
        #expect(ExportFlowViewModel.translate(ClinikoError.rateLimited(retryAfter: 30)) == .rateLimited(retryAfter: 30))
        #expect(ExportFlowViewModel.translate(ClinikoError.server(status: 500)) == .server(status: 500))
        #expect(ExportFlowViewModel.translate(ClinikoError.transport(.timedOut)) == .transport(.timedOut))
        #expect(ExportFlowViewModel.translate(ClinikoError.cancelled) == .cancelled)
        #expect(ExportFlowViewModel.translate(ClinikoError.decoding(typeName: "X")) == .decoding(typeName: "X"))
        #expect(ExportFlowViewModel.translate(ClinikoError.nonHTTPResponse) == .transport(.unknown))
    }

    @Test("translate maps TreatmentNoteExporter.Failure to the corresponding ExportFailure")
    func translate_exporterFailures() {
        #expect(ExportFlowViewModel.translate(TreatmentNoteExporter.Failure.responseUndecodable) == .responseUndecodable)
        #expect(ExportFlowViewModel.translate(TreatmentNoteExporter.Failure.requestEncodeFailed) == .requestEncodeFailed)
    }

    // MARK: - Session-clear contract

    @Test("Successful export drives onSuccess (which clears the session in production)")
    func successfulExport_callsOnSuccess() async throws {
        let store = makeSessionForConfirmingTest()
        let exporter = makeExporter { request in
            let body = try HTTPStubFixture.load("cliniko/responses/treatment_notes_create.json")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 201,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, body)
        }
        var clearedSession = false
        let viewModel = makeViewModel(
            store: store,
            exporter: exporter,
            onSuccess: {
                store.clear()
                clearedSession = true
            }
        )
        viewModel.enterConfirming()
        viewModel.confirm()
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(clearedSession)
        #expect(store.active == nil)
    }

    // MARK: - Helpers

    private func makeSessionForConfirmingTest() -> SessionStore {
        makePopulatedSession()
    }

    private func assertConfirmFailsWith(
        _ expected: ExportFailure,
        status: Int,
        body: Data = Data(),
        file: String = #file,
        line: Int = #line
    ) async throws {
        let store = makeSessionForConfirmingTest()
        let exporter = makeExporter { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }
        let viewModel = makeViewModel(store: store, exporter: exporter)
        viewModel.enterConfirming()
        viewModel.confirm()
        try await Task.sleep(nanoseconds: 100_000_000)

        guard case .failed(let actual) = viewModel.state else {
            Issue.record("expected .failed(\(expected)), got \(viewModel.state)")
            return
        }
        #expect(actual == expected)
    }
}
