// PatientPickerViewRenderTests.swift
// macOS Local Speech-to-Text Application
//
// ViewInspector + crash-detection tests for PatientPickerView.
// Catches the @Observable + actor-existential crash pattern documented
// in `.claude/references/concurrency.md` §1, plus the body-evaluation
// crashes that only surface at runtime.

import SwiftUI
import ViewInspector
import XCTest
@testable import SpeechToText

extension PatientPickerView: Inspectable {}

@MainActor
final class PatientPickerViewRenderTests: XCTestCase {

    // MARK: - Helpers

    private func makeViewModel(
        patientResult: ClinicalNotesPickerStubs.SearchResult = .empty,
        appointmentResult: ClinicalNotesPickerStubs.AppointmentResult = .empty
    ) -> PatientPickerViewModel {
        let store = SessionStore()
        return PatientPickerViewModel(
            patientService: ClinicalNotesPickerStubs.PatientSearcher(result: patientResult),
            appointmentService: ClinicalNotesPickerStubs.AppointmentLoader(result: appointmentResult),
            sessionStore: store,
            debounceMillis: 0
        )
    }

    // MARK: - Crash-detection: instantiation

    /// Critical: catches the `@Observable` + actor-existential pattern
    /// that crashes at runtime if `@ObservationIgnored` is missing.
    func test_picker_instantiatesWithoutCrash() {
        let viewModel = makeViewModel()
        let view = PatientPickerView(viewModel: viewModel)
        XCTAssertNotNil(view)
    }

    /// Critical: body access is where the crash actually surfaces in
    /// production — the executor check fires when SwiftUI walks the
    /// View hierarchy.
    func test_picker_bodyAccessDoesNotCrash() {
        let viewModel = makeViewModel()
        let view = PatientPickerView(viewModel: viewModel)
        let body = view.body
        XCTAssertNotNil(body)
    }

    // MARK: - Phase rendering — the view should not crash in any phase

    func test_picker_idlePhase_rendersWithoutCrash() {
        let viewModel = makeViewModel()
        let view = PatientPickerView(viewModel: viewModel)
        XCTAssertNotNil(view.body)
        XCTAssertEqual(viewModel.searchPhase, .idle)
    }

    func test_picker_searchingPhase_rendersWithoutCrash() async throws {
        let viewModel = makeViewModel()
        viewModel.updateQuery("Sample")
        // The VM transitions through .searching synchronously; the
        // results land asynchronously but we only assert the rendered
        // body doesn't crash mid-flight.
        let view = PatientPickerView(viewModel: viewModel)
        XCTAssertNotNil(view.body)
    }

    func test_picker_resultsPhase_rendersWithoutCrash() async throws {
        let patient = Patient(
            id: "1",
            firstName: "Sample",
            lastName: "Patient",
            dateOfBirth: "1980-01-01",
            email: "sample@example.test"
        )
        let viewModel = makeViewModel(patientResult: .success([patient]))
        viewModel.updateQuery("Sample")
        try await Task.sleep(nanoseconds: 50_000_000)

        let view = PatientPickerView(viewModel: viewModel)
        XCTAssertNotNil(view.body)
        if case .results(let list) = viewModel.searchPhase {
            XCTAssertEqual(list, [patient])
        } else {
            XCTFail("expected .results, got \(viewModel.searchPhase)")
        }
    }

    func test_picker_emptyPhase_rendersWithoutCrash() async throws {
        let viewModel = makeViewModel(patientResult: .success([]))
        viewModel.updateQuery("zzznomatch")
        try await Task.sleep(nanoseconds: 50_000_000)

        let view = PatientPickerView(viewModel: viewModel)
        XCTAssertNotNil(view.body)
        XCTAssertEqual(viewModel.searchPhase, .empty)
    }

    func test_picker_errorPhase_rendersWithoutCrash() async throws {
        let viewModel = makeViewModel(patientResult: .failure(.unauthenticated))
        viewModel.updateQuery("Sample")
        try await Task.sleep(nanoseconds: 50_000_000)

        let view = PatientPickerView(viewModel: viewModel)
        XCTAssertNotNil(view.body)
        XCTAssertEqual(viewModel.searchPhase, .error(.unauthenticated))
    }

    // MARK: - Appointment-pane phases

    /// Regression pin for #127. The previous render path interpolated
    /// `firstName`/`lastName` directly via `\(patient.firstName)`, which
    /// would surface `Optional("...")` after the fields turned nullable
    /// — visually broken AND a PHI-shaped string in the body's view
    /// hierarchy. `Patient.displayName` owns the nil-safe composition;
    /// this test exercises the partial-name and all-nil rows through
    /// the same body access that the production picker uses.
    func test_picker_resultsPhase_partialNames_rendersWithoutCrash() async throws {
        let firstOnly = Patient(id: "2001", firstName: "Sample", lastName: nil)
        let lastOnly = Patient(id: "2002", firstName: nil, lastName: "Subject")
        let bothNil = Patient(id: "2003", firstName: nil, lastName: nil)
        let viewModel = makeViewModel(
            patientResult: .success([firstOnly, lastOnly, bothNil])
        )
        viewModel.updateQuery("partial")
        try await Task.sleep(nanoseconds: 50_000_000)

        let view = PatientPickerView(viewModel: viewModel)
        XCTAssertNotNil(view.body)
        if case .results(let list) = viewModel.searchPhase {
            XCTAssertEqual(list.count, 3)
            XCTAssertEqual(list[0].displayName, "Sample")
            XCTAssertEqual(list[1].displayName, "Subject")
            XCTAssertEqual(list[2].displayName, "Unnamed patient")
        } else {
            XCTFail("expected .results, got \(viewModel.searchPhase)")
        }
    }

    func test_picker_appointmentLoadedPhase_rendersWithoutCrash() async throws {
        let appointment = Appointment(
            id: 9000,
            startsAt: Date(timeIntervalSince1970: 1_700_000_000),
            endsAt: Date(timeIntervalSince1970: 1_700_001_800)
        )
        let viewModel = makeViewModel(appointmentResult: .success([appointment]))
        let store = SessionStore()
        store.start(from: RecordingSession())
        viewModel.selectPatient(Patient(id: "1", firstName: "S", lastName: "P"))
        try await Task.sleep(nanoseconds: 50_000_000)

        let view = PatientPickerView(viewModel: viewModel)
        XCTAssertNotNil(view.body)
    }
}

// MARK: - Test stubs (private to this file via enum namespace)

enum ClinicalNotesPickerStubs {
    enum SearchResult {
        case success([Patient])
        case failure(ClinikoError)
        static var empty: SearchResult { .success([]) }
    }

    enum AppointmentResult {
        case success([Appointment])
        case failure(ClinikoError)
        static var empty: AppointmentResult { .success([]) }
    }

    actor PatientSearcher: ClinikoPatientSearching {
        let result: SearchResult
        init(result: SearchResult) { self.result = result }

        func searchPatients(query: String) async throws -> [Patient] {
            switch result {
            case .success(let patients): return patients
            case .failure(let error): throw error
            }
        }
    }

    actor AppointmentLoader: ClinikoAppointmentLoading {
        let result: AppointmentResult
        init(result: AppointmentResult) { self.result = result }

        func recentAndTodayAppointments(
            forPatientID patientID: String,
            reference: Date
        ) async throws -> [Appointment] {
            switch result {
            case .success(let appointments): return appointments
            case .failure(let error): throw error
            }
        }
    }
}
