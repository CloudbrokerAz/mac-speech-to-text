import Foundation
import Testing
@testable import SpeechToText

/// VM-level tests for `PatientPickerViewModel`. These exercise the
/// debounce + cancellation contract from #9's acceptance criteria using
/// in-test actor fakes for the patient / appointment services. No HTTP
/// stub here — the service layer is covered by the XCTest-based service
/// tests; this suite is about the VM's own state machine.
///
/// `@Suite(.serialized)` because `@MainActor` work isn't inherently
/// parallel-safe across these tests when each one drives a fresh
/// SessionStore.
@Suite("PatientPickerViewModel", .tags(.fast), .serialized)
@MainActor
struct PatientPickerViewModelTests {

    // MARK: - Debounce

    @Test("first keystroke does not call the patient service before debounce expires")
    func debounce_firstKeystroke_noNetworkCall() async throws {
        let patients = FakePatientSearcher(result: .success([]))
        let appointments = FakeAppointmentLoader(result: .success([]))
        let store = SessionStore()
        let vm = PatientPickerViewModel(
            patientService: patients,
            appointmentService: appointments,
            sessionStore: store,
            debounceMillis: 100
        )

        vm.updateQuery("S")

        // Don't sleep at all — give the runtime a single yield so the
        // sleep-task is scheduled, then assert no call has been made.
        await Task.yield()

        let count = await patients.callCount
        #expect(count == 0)
    }

    @Test("rapid keystrokes within the debounce window collapse to a single call")
    func debounce_rapidKeystrokes_singleCall() async throws {
        let patients = FakePatientSearcher(result: .success([]))
        let appointments = FakeAppointmentLoader(result: .success([]))
        let store = SessionStore()
        let vm = PatientPickerViewModel(
            patientService: patients,
            appointmentService: appointments,
            sessionStore: store,
            debounceMillis: 30
        )

        vm.updateQuery("S")
        vm.updateQuery("Sa")
        vm.updateQuery("Sam")
        vm.updateQuery("Samp")
        vm.updateQuery("Sample")

        // Wait long enough for the debounce + a small buffer, then settle
        // any continuations.
        try await Task.sleep(nanoseconds: 150_000_000)

        let count = await patients.callCount
        let lastQuery = await patients.lastQuery
        #expect(count == 1)
        #expect(lastQuery == "Sample")
    }

    @Test("whitespace-only query resets to .idle without firing a search")
    func whitespaceQuery_idle_noCall() async throws {
        let patients = FakePatientSearcher(result: .success([]))
        let appointments = FakeAppointmentLoader(result: .success([]))
        let store = SessionStore()
        let vm = PatientPickerViewModel(
            patientService: patients,
            appointmentService: appointments,
            sessionStore: store,
            debounceMillis: 0
        )

        vm.updateQuery("   ")
        try await Task.sleep(nanoseconds: 50_000_000)

        let count = await patients.callCount
        #expect(count == 0)
        #expect(vm.searchPhase == .idle)
    }

    // MARK: - Phase transitions

    @Test("non-empty result populates .results")
    func search_results() async throws {
        let patient = Patient(id: 1, firstName: "Sample", lastName: "Patient")
        let patients = FakePatientSearcher(result: .success([patient]))
        let appointments = FakeAppointmentLoader(result: .success([]))
        let store = SessionStore()
        let vm = PatientPickerViewModel(
            patientService: patients,
            appointmentService: appointments,
            sessionStore: store,
            debounceMillis: 0
        )

        vm.updateQuery("Sample")
        try await Task.sleep(nanoseconds: 50_000_000)

        if case .results(let list) = vm.searchPhase {
            #expect(list == [patient])
        } else {
            Issue.record("expected .results, got \(vm.searchPhase)")
        }
    }

    @Test("empty result populates .empty")
    func search_empty() async throws {
        let patients = FakePatientSearcher(result: .success([]))
        let appointments = FakeAppointmentLoader(result: .success([]))
        let store = SessionStore()
        let vm = PatientPickerViewModel(
            patientService: patients,
            appointmentService: appointments,
            sessionStore: store,
            debounceMillis: 0
        )

        vm.updateQuery("zzznomatch")
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(vm.searchPhase == .empty)
    }

    @Test("service error surfaces as .error(error)")
    func search_error() async throws {
        let patients = FakePatientSearcher(result: .failure(.unauthenticated))
        let appointments = FakeAppointmentLoader(result: .success([]))
        let store = SessionStore()
        let vm = PatientPickerViewModel(
            patientService: patients,
            appointmentService: appointments,
            sessionStore: store,
            debounceMillis: 0
        )

        vm.updateQuery("anything")
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(vm.searchPhase == .error(.unauthenticated))
    }

    @Test(".cancelled service errors are swallowed silently")
    func search_cancelled_silent() async throws {
        let patients = FakePatientSearcher(result: .failure(.cancelled))
        let appointments = FakeAppointmentLoader(result: .success([]))
        let store = SessionStore()
        let vm = PatientPickerViewModel(
            patientService: patients,
            appointmentService: appointments,
            sessionStore: store,
            debounceMillis: 0
        )

        vm.updateQuery("anything")
        try await Task.sleep(nanoseconds: 50_000_000)

        // `.cancelled` doesn't render an error to the user (the typing-
        // race case), but the VM resets the stuck `.searching` phase to
        // `.idle` so the UI never spins forever waiting for a result
        // that won't come.
        #expect(vm.searchPhase == .idle)
    }

    // MARK: - Patient selection

    @Test("selecting a patient writes selectedPatientID to the SessionStore")
    func selectPatient_writesToSession() async throws {
        let store = SessionStore()
        // Need a recording session to start the SessionStore lifecycle.
        let recording = RecordingSession.empty()
        store.start(from: recording)

        let appointments = FakeAppointmentLoader(result: .success([]))
        let patients = FakePatientSearcher(result: .success([]))
        let vm = PatientPickerViewModel(
            patientService: patients,
            appointmentService: appointments,
            sessionStore: store,
            debounceMillis: 0
        )

        let patient = Patient(id: 1234, firstName: "Sample", lastName: "Patient")
        vm.selectPatient(patient)

        #expect(store.active?.selectedPatientID == "1234")
        #expect(vm.selectedPatient == patient)
        #expect(vm.appointmentPhase == .loading)
    }

    @Test("selectAppointment(id:) writes to the SessionStore; nil = no appointment")
    func selectAppointment_writesToSession() async throws {
        let store = SessionStore()
        store.start(from: RecordingSession.empty())

        let patients = FakePatientSearcher(result: .success([]))
        let appointments = FakeAppointmentLoader(result: .success([]))
        let vm = PatientPickerViewModel(
            patientService: patients,
            appointmentService: appointments,
            sessionStore: store,
            debounceMillis: 0
        )

        vm.selectAppointment(id: 5678)
        #expect(store.active?.selectedAppointmentID == "5678")
        #expect(vm.selectedAppointmentID == 5678)

        vm.selectAppointment(id: nil)
        #expect(store.active?.selectedAppointmentID == nil)
        #expect(vm.selectedAppointmentID == nil)
    }

    // MARK: - Appointment loading

    @Test("after patient selection, appointmentPhase reaches .loaded with the fake's results")
    func appointmentPhase_loaded() async throws {
        let store = SessionStore()
        store.start(from: RecordingSession.empty())

        let appointment = Appointment(
            id: 9000,
            startsAt: Date(timeIntervalSince1970: 1_700_000_000),
            endsAt: Date(timeIntervalSince1970: 1_700_001_800)
        )
        let patients = FakePatientSearcher(result: .success([]))
        let appointments = FakeAppointmentLoader(result: .success([appointment]))
        let vm = PatientPickerViewModel(
            patientService: patients,
            appointmentService: appointments,
            sessionStore: store,
            debounceMillis: 0
        )

        vm.selectPatient(Patient(id: 1, firstName: "S", lastName: "P"))
        try await Task.sleep(nanoseconds: 50_000_000)

        if case .loaded(let list) = vm.appointmentPhase {
            #expect(list == [appointment])
        } else {
            Issue.record("expected .loaded, got \(vm.appointmentPhase)")
        }
    }

    @Test("appointment service error surfaces as .error")
    func appointmentPhase_error() async throws {
        let store = SessionStore()
        store.start(from: RecordingSession.empty())

        let patients = FakePatientSearcher(result: .success([]))
        let appointments = FakeAppointmentLoader(result: .failure(.transport(.notConnectedToInternet)))
        let vm = PatientPickerViewModel(
            patientService: patients,
            appointmentService: appointments,
            sessionStore: store,
            debounceMillis: 0
        )

        vm.selectPatient(Patient(id: 1, firstName: "S", lastName: "P"))
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(vm.appointmentPhase == .error(.transport(.notConnectedToInternet)))
    }

    // MARK: - Clear

    @Test("clearSelection resets state and clears SessionStore selections")
    func clearSelection_resets() async throws {
        let store = SessionStore()
        store.start(from: RecordingSession.empty())

        let patients = FakePatientSearcher(result: .success([]))
        let appointments = FakeAppointmentLoader(result: .success([]))
        let vm = PatientPickerViewModel(
            patientService: patients,
            appointmentService: appointments,
            sessionStore: store,
            debounceMillis: 0
        )

        vm.selectPatient(Patient(id: 1, firstName: "S", lastName: "P"))
        vm.selectAppointment(id: 9)
        vm.clearSelection()

        #expect(vm.selectedPatient == nil)
        #expect(vm.selectedAppointmentID == nil)
        #expect(vm.searchPhase == .idle)
        #expect(vm.appointmentPhase == .idle)
        #expect(store.active?.selectedPatientID == nil)
        #expect(store.active?.selectedAppointmentID == nil)
    }
}

// MARK: - In-test actor fakes

/// Fake `ClinikoPatientSearching`. Records each call so tests can assert on
/// the call count and last query.
actor FakePatientSearcher: ClinikoPatientSearching {
    enum FakeResult {
        case success([Patient])
        case failure(ClinikoError)
    }

    var result: FakeResult
    private(set) var callCount: Int = 0
    private(set) var lastQuery: String?

    init(result: FakeResult) {
        self.result = result
    }

    func searchPatients(query: String) async throws -> [Patient] {
        callCount += 1
        lastQuery = query
        switch result {
        case .success(let patients): return patients
        case .failure(let error): throw error
        }
    }
}

/// Fake `ClinikoAppointmentLoading`. Records the last patientID + reference.
actor FakeAppointmentLoader: ClinikoAppointmentLoading {
    enum FakeResult {
        case success([Appointment])
        case failure(ClinikoError)
    }

    var result: FakeResult
    private(set) var callCount: Int = 0
    private(set) var lastPatientID: String?
    private(set) var lastReference: Date?

    init(result: FakeResult) {
        self.result = result
    }

    func recentAndTodayAppointments(
        forPatientID patientID: String,
        reference: Date
    ) async throws -> [Appointment] {
        callCount += 1
        lastPatientID = patientID
        lastReference = reference
        switch result {
        case .success(let appointments): return appointments
        case .failure(let error): throw error
        }
    }
}

// MARK: - RecordingSession test helper

/// Local helper for tests that need a `RecordingSession` placeholder. We
/// keep this scoped to the test file rather than `RecordingSession.swift`
/// itself so production callers can't accidentally instantiate "empty".
private extension RecordingSession {
    static func empty() -> RecordingSession {
        RecordingSession()
    }
}
