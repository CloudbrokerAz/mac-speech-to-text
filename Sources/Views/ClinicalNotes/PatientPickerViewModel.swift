import Foundation
import Observation
import os.log

/// Picker view-model for selecting a Cliniko patient + (optionally) one of
/// their recent appointments. Owns the debounced search lifecycle, swaps
/// the active patient + appointment-list phase, and writes selections
/// through to the supplied `SessionStore`.
///
/// PHI: query strings, patient names, DOBs, and appointment timing all
/// flow through this VM. None of them are logged. Service references are
/// `@ObservationIgnored` so the existential-actor + `@Observable`
/// crash-pattern from `.claude/references/concurrency.md` §1 stays
/// avoided.
@Observable
@MainActor
final class PatientPickerViewModel: Identifiable {

    /// Stable identity for SwiftUI `.sheet(item:)` hosting (#14).
    /// One picker presentation gets one VM; closing the sheet
    /// drops the reference and the next presentation builds a
    /// fresh VM.
    nonisolated let id = UUID()

    /// Phase machine for the patient-search panel.
    enum SearchPhase: Sendable, Equatable {
        case idle
        case searching
        case results([Patient])
        case empty
        case error(ClinikoError)
    }

    /// Phase machine for the per-patient appointments panel.
    enum AppointmentPhase: Sendable, Equatable {
        case idle
        case loading
        case loaded([Appointment])
        case error(ClinikoError)
    }

    // MARK: - Observed state

    /// The current debounced query value. Bound from the search field via
    /// `updateQuery(_:)` rather than a writable property, so the VM owns
    /// the cancellation + debounce semantics.
    private(set) var query: String = ""

    private(set) var searchPhase: SearchPhase = .idle

    private(set) var selectedPatient: Patient?

    private(set) var appointmentPhase: AppointmentPhase = .idle

    /// Local mirror of `ClinicalSession.selectedAppointmentID`, kept as an
    /// `Int?` for the picker UI. `nil` means "No appointment / general
    /// note" (the post-recording note doesn't tie to an appointment).
    private(set) var selectedAppointmentID: Int?

    // MARK: - Dependencies

    @ObservationIgnored private let patientService: any ClinikoPatientSearching
    @ObservationIgnored private let appointmentService: any ClinikoAppointmentLoading
    @ObservationIgnored private let sessionStore: SessionStore
    @ObservationIgnored private let debounceMillis: UInt64
    @ObservationIgnored private let now: @Sendable () -> Date

    // MARK: - Mutable internal state

    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var appointmentTask: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger(
        subsystem: "com.speechtotext",
        category: "PatientPickerViewModel"
    )

    // MARK: - Init

    /// - Parameters:
    ///   - patientService / appointmentService: the actor-constrained
    ///     services. Tests pass in-test actor fakes.
    ///   - sessionStore: where patient / appointment selections are
    ///     persisted within the active `ClinicalSession`.
    ///   - debounceMillis: how long to wait after the last keystroke
    ///     before issuing a search. Tests pass `0` to bypass.
    ///   - now: clock for the `recentAndTodayAppointments(reference:)`
    ///     anchor — `Date()` in production, fixed in tests.
    init(
        patientService: any ClinikoPatientSearching,
        appointmentService: any ClinikoAppointmentLoading,
        sessionStore: SessionStore,
        debounceMillis: UInt64 = 300,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.patientService = patientService
        self.appointmentService = appointmentService
        self.sessionStore = sessionStore
        self.debounceMillis = debounceMillis
        self.now = now
    }

    // MARK: - Search

    /// Update the search query. Cancels any in-flight search task and
    /// schedules a new debounced one. Empty / whitespace-only queries
    /// reset the panel to `.idle` without firing a network call —
    /// satisfying #9's "first keystroke → no network call" acceptance.
    func updateQuery(_ newQuery: String) {
        query = newQuery
        searchTask?.cancel()
        let trimmed = newQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchPhase = .idle
            return
        }
        let debounce = debounceMillis
        searchTask = Task { [weak self] in
            if debounce > 0 {
                do {
                    try await Task.sleep(nanoseconds: debounce * 1_000_000)
                } catch {
                    return  // cancelled — caller already replaced the task.
                }
            }
            // After the debounce window, re-check cancellation before
            // issuing the network request. Without this, a fast typist
            // can race the cancel with the sleep return.
            guard !Task.isCancelled else { return }
            await self?.performSearch(trimmed)
        }
    }

    private func performSearch(_ trimmed: String) async {
        searchPhase = .searching
        do {
            let patients = try await patientService.searchPatients(query: trimmed)
            // Stale-result guard: if the query was further mutated while
            // we were awaiting, a new searchTask is already in flight;
            // reset to `.idle` rather than leave the UI stuck on
            // `.searching` if no follow-up search task fires (e.g. host
            // view dismissed mid-flight).
            guard !Task.isCancelled else {
                if searchPhase == .searching { searchPhase = .idle }
                return
            }
            searchPhase = patients.isEmpty ? .empty : .results(patients)
        } catch let error as ClinikoError {
            // For `.cancelled`, only swallow + reset to `.idle` if our
            // local task was actually cancelled (the typing-race case
            // — `searchTask?.cancel()` propagates `Task.isCancelled =
            // true` through structured concurrency to the awaited
            // service call). A `.cancelled` arriving without
            // `Task.isCancelled` would be a URLSession-level cancel
            // (session invalidation, etc.) — surface that as an error
            // so the UI doesn't silently lose state. Mirrors the
            // identical check in `loadAppointments`.
            if case .cancelled = error {
                if Task.isCancelled {
                    if searchPhase == .searching { searchPhase = .idle }
                    return
                }
                searchPhase = .error(error)
                return
            }
            searchPhase = .error(error)
        } catch is CancellationError {
            if searchPhase == .searching { searchPhase = .idle }
            return
        } catch {
            // The service layer is contractually `throws ClinikoError`
            // only — anything else is a programmer bug we want to know
            // about. Crash in DEBUG so it gets caught in test/dev; in
            // RELEASE, log structurally and degrade to a transport-
            // shaped error so the UI has something concrete to render.
            // PHI: only the Swift type name is logged (structural).
            let typeName = String(reflecting: Swift.type(of: error))
            logger.error(
                "PatientPickerViewModel: non-ClinikoError from patientService type=\(typeName, privacy: .public)"
            )
            assertionFailure("PatientPickerViewModel: non-ClinikoError from patientService: \(typeName)")
            searchPhase = .error(.transport(.unknown))
        }
    }

    // MARK: - Selection

    /// Select a patient. Clears any prior appointment selection, kicks
    /// off the appointment-list load, and writes through to the session
    /// store immediately so downstream UI (export panel) sees the
    /// selection without waiting on the appointment fetch.
    func selectPatient(_ patient: Patient) {
        selectedPatient = patient
        // Pass the display name through with the ID so the export
        // confirmation surface (#14) can render a patient label
        // without re-fetching. The two never drift because
        // `setSelectedPatient(id:displayName:)` clears the name
        // whenever the id is cleared.
        let displayName = "\(patient.firstName) \(patient.lastName)".trimmingCharacters(in: .whitespaces)
        sessionStore.setSelectedPatient(
            id: OpaqueClinikoID(patient.id),
            displayName: displayName
        )
        sessionStore.setSelectedAppointment(id: nil)
        selectedAppointmentID = nil
        appointmentPhase = .loading
        appointmentTask?.cancel()
        appointmentTask = Task { [weak self] in
            await self?.loadAppointments(for: patient)
        }
    }

    private func loadAppointments(for patient: Patient) async {
        let reference = now()
        do {
            let appointments = try await appointmentService.recentAndTodayAppointments(
                forPatientID: String(patient.id),
                reference: reference
            )
            // See `performSearch` for the cancel-guard rationale.
            guard !Task.isCancelled else {
                if appointmentPhase == .loading { appointmentPhase = .idle }
                return
            }
            appointmentPhase = .loaded(appointments)
        } catch let error as ClinikoError {
            // `.cancelled` from the service is only safe to swallow
            // when our local task was actually cancelled (the user
            // picked a different patient or dismissed the picker).
            // A URLSession-level cancel that arrives without our task
            // being cancelled is a real failure the user should see.
            if case .cancelled = error {
                if Task.isCancelled {
                    if appointmentPhase == .loading { appointmentPhase = .idle }
                    return
                }
                appointmentPhase = .error(error)
                return
            }
            appointmentPhase = .error(error)
        } catch is CancellationError {
            if appointmentPhase == .loading { appointmentPhase = .idle }
            return
        } catch {
            // Same contract as performSearch — service layer is
            // `throws ClinikoError` only.
            let typeName = String(reflecting: Swift.type(of: error))
            logger.error(
                "PatientPickerViewModel: non-ClinikoError from appointmentService type=\(typeName, privacy: .public)"
            )
            assertionFailure("PatientPickerViewModel: non-ClinikoError from appointmentService: \(typeName)")
            appointmentPhase = .error(.transport(.unknown))
        }
    }

    /// Select an appointment, or `nil` for "No appointment / general
    /// note". Writes through to the session store, type-tagging the Int
    /// into `OpaqueClinikoID` (#59) at the SessionStore boundary.
    func selectAppointment(id: Int?) {
        selectedAppointmentID = id
        sessionStore.setSelectedAppointment(id: id.map(OpaqueClinikoID.init))
    }

    /// Clear the entire selection state. Used by the host view when the
    /// picker is dismissed without confirmation.
    func clearSelection() {
        searchTask?.cancel()
        appointmentTask?.cancel()
        selectedPatient = nil
        selectedAppointmentID = nil
        appointmentPhase = .idle
        searchPhase = .idle
        query = ""
        sessionStore.setSelectedPatient(id: nil)
        sessionStore.setSelectedAppointment(id: nil)
    }

    // MARK: - Test seams

    /// Test seam — exposes the currently-scheduled debounced search task
    /// so a test can `await currentSearchTaskForTests?.value` instead of
    /// gambling on a wall-clock `Task.sleep` to elapse. The previous
    /// timing-based shape (5 ms debounce + 250 ms wait, paper-budget
    /// 50× headroom) was flaky on loaded GitHub-Actions macOS-15
    /// runners — `Task.sleep` schedule jitter on a busy host can spike
    /// past the wait budget even when the wait is technically longer
    /// in wall-clock terms (#117 / previous mitigation in #56).
    /// Awaiting the task's `value` is a deterministic synchronisation
    /// point that doesn't care about wall-clock at all.
    ///
    /// Production callers MUST NOT use this — the search task lifecycle
    /// is owned by `updateQuery(_:)` / `clearSelection()`. The accessor
    /// is `internal` so test code can reach it via `@testable import`.
    @ObservationIgnored
    internal var currentSearchTaskForTests: Task<Void, Never>? {
        searchTask
    }

    /// Test seam — exposes the currently-scheduled appointment-load task
    /// for the same `await … .value` shape as `currentSearchTaskForTests`.
    /// Used by `appointmentPhase_loaded` and `appointmentPhase_error`
    /// after `selectPatient(_:)` kicks off the load.
    @ObservationIgnored
    internal var currentAppointmentTaskForTests: Task<Void, Never>? {
        appointmentTask
    }
}
