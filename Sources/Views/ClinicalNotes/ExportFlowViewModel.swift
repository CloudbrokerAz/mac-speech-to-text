// ExportFlowViewModel.swift
// macOS Local Speech-to-Text Application
//
// FSM-driven view model behind ExportFlowView (#14). Hosts the
// "review patient + appointment + note summary → POST → success /
// failure" cycle that closes the EPIC #1 export loop.
//
// Architecture:
//   - Confirming state pre-flights the wire body (resolves
//     manipulations, computes char counts, surfaces dropped IDs)
//     without touching the network — the practitioner gets a final
//     read of what's about to leave the device.
//   - Uploading state calls `TreatmentNoteExporter.export(...)` once
//     (Cliniko POSTs are non-idempotent — see
//     `.claude/references/cliniko-api.md` §"Retry policy"). All
//     retries are user-confirmed and re-enter the uploading state.
//   - Succeeded clears `SessionStore` and dismisses the review
//     window; the audit row is already on disk by this point.
//   - Failed translates `ClinikoError` / `TreatmentNoteExporter.Failure`
//     into a UI-shaped `ExportFailure` enum the view switches on.
//
// PHI: SOAP body, patient name, transcript — none cross the log
// boundary from this VM. State transitions log the FSM case name +
// structural counters only. See `.claude/references/phi-handling.md`.

import Foundation
import Observation
import OSLog

// MARK: - ExportFlowState

/// Finite-state machine for the export sheet. Discrete cases — no
/// boolean flags — so the view can render exactly one state at a
/// time and there's a single source of truth for the FSM's current
/// position.
enum ExportFlowState: Sendable, Equatable {
    /// Sheet just opened; the VM is about to compute the
    /// confirmation summary. Brief — usually the next render cycle
    /// transitions to `.confirming`.
    case idle

    /// Confirmation step: practitioner reviews patient + appointment
    /// + section char counts + dropped manipulation IDs before
    /// hitting Confirm. No network activity.
    case confirming(ExportSummary)

    /// In-flight Cliniko POST. The view shows a frosted progress
    /// indicator. Cancel is disabled (the request is already on the
    /// wire and a user-cancel post-send would create the same
    /// "did the note land or not?" ambiguity as a transport error).
    case uploading

    /// POST landed; audit row was attempted (best-effort — see
    /// `ExportOutcome.auditPersisted`). View shows a one-shot
    /// success surface, then the host closes the review window.
    case succeeded(SuccessReport)

    /// POST or pre-flight failed. View renders `reason` and offers
    /// the affordances appropriate to the failure (retry, copy to
    /// clipboard, open Cliniko settings, open browser).
    case failed(ExportFailure)
}

// MARK: - ExportSummary

/// Pre-flight summary surfaced in the confirmation step. Computed
/// once on entry from the active session + manipulations repository
/// so the view doesn't recompute on every render.
///
/// PHI: every field except the IDs is bounded by an `Int` count —
/// the actual SOAP body never lands here. The view renders "Subjective:
/// 412 chars" not "Subjective: '...content...'".
struct ExportSummary: Sendable, Equatable {
    /// Patient ID (opaque Cliniko ID, `OpaqueClinikoID(_:String)` form
    /// per Cliniko's documented `string($int64)` patient-id wire shape —
    /// see #127).
    let patientID: OpaqueClinikoID
    /// Patient name for display. The picker captures this at
    /// selection time so the export sheet doesn't have to refetch.
    let patientDisplayName: String
    /// Resolved appointment selection.
    let appointment: AppointmentSelection
    /// Per-section character counts for the SOAP body. Drives the
    /// "Subjective: 412 chars" preview rows.
    let sectionCounts: [SectionCount]
    /// Manipulation display names that resolved into the wire body.
    let resolvedManipulations: [String]
    /// Manipulation IDs the practitioner had selected but that the
    /// taxonomy no longer carries (placeholder-to-real-taxonomy swap
    /// removed an entry). Surfaced as a yellow warning bar so the
    /// practitioner can re-pick a current manipulation before
    /// submitting.
    let droppedManipulationIDs: [String]
    /// Count of LLM-excluded snippets the practitioner has not
    /// re-added. Surfaced so the practitioner sees "N excluded
    /// snippets are NOT being exported" before hitting Confirm.
    let excludedNotExportedCount: Int

    struct SectionCount: Sendable, Equatable, Identifiable {
        let field: SOAPField
        let charCount: Int
        var id: SOAPField { field }
    }
}

// MARK: - SuccessReport

/// Surfaced by `.succeeded` and consumed by the host
/// (`ExportFlowCoordinator`) to drive the post-success window
/// dismiss + toast. Carries `auditPersisted` so the host can render
/// "exported successfully — audit log unavailable" when the POST
/// landed but `audit.jsonl` couldn't be written.
struct SuccessReport: Sendable, Equatable {
    /// Cliniko's `treatment_note.id` from the 201 response, type-
    /// tagged via `OpaqueClinikoID(_:Int)` at this boundary.
    let createdNoteID: OpaqueClinikoID
    /// `false` when the POST landed but `AuditStore.record(_:)`
    /// failed. The host MUST still treat this as success — re-
    /// submitting would create a duplicate clinical record on
    /// Cliniko's side.
    let auditPersisted: Bool
    /// Manipulation IDs the practitioner had selected that the
    /// current taxonomy no longer carries. Mirrors
    /// `ExportSummary.droppedManipulationIDs` so the toast can
    /// optionally surface "Submitted; N stale manipulations
    /// dropped".
    let droppedManipulationIDs: [String]
}

// MARK: - ExportFailure

/// UI-shaped translation of `ClinikoError` and
/// `TreatmentNoteExporter.Failure`. Each case maps to a deliberate
/// affordance the practitioner can take — the view doesn't decide
/// "which buttons to show" by inspecting an error type, it switches
/// on this enum.
enum ExportFailure: Error, Sendable, Equatable {
    /// 401 — Cliniko rejected the API key. UI offers "Open Cliniko
    /// Settings".
    case unauthenticated
    /// 403 — key valid but lacks scope. UI offers "Open Cliniko
    /// Settings" with a different message ("ask your Cliniko admin
    /// for treatment-note write access").
    case forbidden
    /// 404 — patient or appointment not visible. UI offers
    /// "Re-pick patient" by dismissing the sheet so the
    /// practitioner can reopen the picker from the header.
    case notFound(resource: ClinikoError.Resource)
    /// 422 — Cliniko surfaced field-level validation errors. UI
    /// renders the field map and stays editable behind the sheet
    /// (close + edit + retry).
    case validation(fields: [String: [String]])
    /// 429 — rate-limit exhausted past the client's budget. UI
    /// renders a countdown built from `retryAfter` (defaulting to
    /// 60s when nil) and disables Retry until the countdown
    /// completes.
    case rateLimited(retryAfter: TimeInterval?)
    /// 5xx after any allowed retries. POST is non-idempotent so the
    /// client doesn't retry — UI offers user-confirmed retry.
    case server(status: Int)
    /// URLSession-level transport error (offline / DNS / TLS). UI
    /// offers retry **and** "Copy to clipboard" so the
    /// practitioner can keep working from a paper-or-other-app
    /// fallback.
    case transport(URLError.Code)
    /// 2xx + body undecodable. The note **may** have landed on
    /// Cliniko's side. UI deliberately does NOT offer one-tap
    /// retry — it offers "Open Cliniko in browser" + "Copy note"
    /// so the practitioner can verify before potentially
    /// double-writing.
    case responseUndecodable
    /// `JSONEncoder.encode(TreatmentNotePayload)` failed.
    /// Effectively unreachable in production (every field is a
    /// primitive); UI surfaces a "Copy to clipboard + retry"
    /// fallback.
    case requestEncodeFailed
    /// User-initiated cancel arriving from the structured-
    /// concurrency layer or URLSession. UI dismisses silently.
    case cancelled
    /// `ClinikoError.decoding` for non-treatment-note endpoints
    /// (defensive; the export path uses `responseUndecodable`).
    case decoding(typeName: String)
    /// Pre-flight invariant violation: the active session lost its
    /// patient or selection state between the confirm tap and the
    /// POST. UI shows "Re-select patient and try again" and
    /// dismisses the sheet so the picker can reopen.
    case sessionState(SessionStateFailure)

    /// Specific pre-flight session-state failures, distinguished so
    /// the UI can surface a precise message.
    enum SessionStateFailure: Sendable, Equatable {
        /// `SessionStore.active` was nil at the moment of confirm
        /// (idle timeout fired, or the host cleared the session).
        case noActiveSession
        /// `selectedPatientID` was nil — the picker hasn't run, or
        /// was reset.
        case noPatient
        /// `selectedPatientID.intValue` returned nil — a tampered
        /// audit-ledger replay landed in the session, or a future
        /// non-numeric Cliniko ID shape entered. Either way, we
        /// can't build the wire payload.
        case patientIDMalformed
        /// The selected appointment's `OpaqueClinikoID.rawValue` could
        /// not be parsed as `Int` — same class as `patientIDMalformed`
        /// (#127), now applied to `Appointment.id` after #129 flipped
        /// it to `String`. Without this guard, a malformed appointment
        /// id would silently degrade the export to a general note,
        /// losing the appointment linkage with no user-visible signal.
        case appointmentIDMalformed
        /// `appointment` resolved to `.unset` — the practitioner
        /// hasn't chosen between "an appointment" and "no
        /// appointment". The confirm UI is gated on this; reaching
        /// the failure case means a defensive guard fired.
        case appointmentUnresolved
        /// `draftNotes` was nil — the LLM never produced a draft
        /// and the practitioner hit Confirm without composing
        /// from raw transcript.
        case noDraftNotes
    }
}

// MARK: - ExportFlowDependencies

/// Dependency bag for the VM. Lets `ExportFlowCoordinator` wire
/// real services in production and lets tests pass fakes via the
/// per-field initialiser.
///
/// `closeReviewWindow` is the post-success dismissal hook —
/// `ExportFlowCoordinator` wires this to
/// `ReviewWindowController.shared.close()`. `openClinikoSettings`
/// drives the 401 / 403 routing — the AppState helper added in this
/// PR resolves to `MainWindowController.shared.showSection(.clinicalNotes)`.
@MainActor
struct ExportFlowDependencies {
    let exporter: TreatmentNoteExporter
    let manipulations: ManipulationsRepository
    /// Called after a successful export — the audit row is already
    /// on disk by this point. Implementations should clear
    /// `SessionStore` and close the review window in that order.
    let onSuccess: () -> Void
    /// Called when the failure case routes the practitioner to the
    /// Cliniko credentials surface (401 / 403).
    let openClinikoSettings: () -> Void
    /// Called when the practitioner copies the SOAP body to the
    /// clipboard from the offline-fallback affordance. Default
    /// impl uses `NSPasteboard.general` in production; tests pass
    /// a hook to assert the call.
    let copyToClipboard: (String) -> Void
}

// MARK: - ExportFlowViewModel

/// `@Observable @MainActor` VM driving the export sheet. Holds the
/// FSM state, owns the single in-flight Task during `.uploading`,
/// and exposes the affordance callbacks the view binds to.
///
/// Service references are `@ObservationIgnored` per
/// `.claude/references/concurrency.md` §1 — `TreatmentNoteExporter`
/// is an actor existential, which would crash a vanilla `@Observable`
/// scan.
///
/// `Identifiable` so the host (`ReviewScreen`) can present the
/// sheet via `.sheet(item:)` rather than `.sheet(isPresented:)` —
/// the item-bound form re-uses the VM across renders without
/// rebuilding it on every state change. `id` is stable for the
/// VM's lifetime; once the sheet dismisses, the host drops the
/// reference and a fresh VM is built on the next Export tap.
@Observable
@MainActor
final class ExportFlowViewModel: Identifiable {

    // MARK: - Identifiable

    let id = UUID()

    // MARK: - Observed state

    private(set) var state: ExportFlowState = .idle

    /// Countdown timer remaining for `.failed(.rateLimited)`. Nil
    /// when no rate-limit surface is showing. Decremented by a
    /// driver Task; reaches 0 to enable the Retry button.
    private(set) var rateLimitCountdownRemaining: TimeInterval?

    // MARK: - Dependencies

    @ObservationIgnored private let sessionStore: SessionStore
    @ObservationIgnored private let dependencies: ExportFlowDependencies

    // MARK: - Mutable internal state

    @ObservationIgnored private var uploadTask: Task<Void, Never>?
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    /// Nonisolated mirrors of the in-flight tasks so `deinit` (which
    /// runs nonisolated) can cancel them without an actor hop. The
    /// `nonisolated(unsafe)` annotation is justified because: (a)
    /// every assignment happens on `@MainActor`, (b) `deinit` is the
    /// only nonisolated reader, and (c) `deinit` runs after every
    /// other reference has been dropped, so there is no concurrent
    /// access. Same idiom as `AppState.deinitLoadingTask`.
    @ObservationIgnored private nonisolated(unsafe) var deinitUploadTask: Task<Void, Never>?
    @ObservationIgnored private nonisolated(unsafe) var deinitCountdownTask: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger(
        subsystem: "com.speechtotext",
        category: "ExportFlowViewModel"
    )

    // MARK: - Init

    init(
        sessionStore: SessionStore,
        dependencies: ExportFlowDependencies
    ) {
        self.sessionStore = sessionStore
        self.dependencies = dependencies
    }

    deinit {
        // Cancel any in-flight upload / countdown Tasks at sheet
        // dismissal so they don't continue past the VM's lifetime.
        // The Tasks already capture `[weak self]` so `await self?.…`
        // would no-op once self is gone, but cancelling explicitly
        // tears down the structured-concurrency tree faster (avoids
        // a stuck `Task.sleep(for: .seconds(1))` lingering for a
        // wall-clock second after the user dismisses).
        deinitUploadTask?.cancel()
        deinitCountdownTask?.cancel()
    }

    // MARK: - Lifecycle

    /// Compute the confirmation summary from the active session +
    /// manipulations and transition to `.confirming`. Idempotent —
    /// a re-entry from `.failed` after a Retry → Cancel returns to
    /// the same `.confirming(summary)` shape.
    func enterConfirming() {
        switch buildSummary() {
        case .success(let summary):
            state = .confirming(summary)
            logger.info("ExportFlowViewModel: state=confirming sectionCount=\(summary.sectionCounts.count, privacy: .public) dropped=\(summary.droppedManipulationIDs.count, privacy: .public)")
        case .failure(let failure):
            state = .failed(failure)
            logger.error("ExportFlowViewModel: state=failed reason=preflight")
        }
    }

    /// Update the appointment selection from the picker
    /// affordance hosted on the confirmation step. Re-renders
    /// the summary so the gate flips when the practitioner
    /// chooses .general / .appointment.
    func setAppointmentSelection(_ selection: AppointmentSelection) {
        guard case .confirming(let summary) = state else { return }
        state = .confirming(ExportSummary(
            patientID: summary.patientID,
            patientDisplayName: summary.patientDisplayName,
            appointment: selection,
            sectionCounts: summary.sectionCounts,
            resolvedManipulations: summary.resolvedManipulations,
            droppedManipulationIDs: summary.droppedManipulationIDs,
            excludedNotExportedCount: summary.excludedNotExportedCount
        ))
    }

    /// Confirm the export and kick off the POST. Gated on the
    /// summary's appointment being resolved (`.unset` is rejected).
    /// Single in-flight Task — re-entry while uploading is a
    /// no-op (the button is disabled, but defence-in-depth).
    func confirm() {
        guard case .confirming(let summary) = state else { return }
        guard summary.appointment.isResolved else {
            state = .failed(.sessionState(.appointmentUnresolved))
            logger.error("ExportFlowViewModel: confirm blocked — appointment unresolved")
            return
        }
        guard uploadTask == nil else {
            logger.error("ExportFlowViewModel: confirm dropped — upload already in flight")
            return
        }
        guard let patientIDInt = Int(summary.patientID.rawValue) else {
            // Cliniko's documented `Patient.id` shape is `string($int64)`
            // (#127). In practice every tenant emits a numeric literal
            // and `TreatmentNoteExporter` still speaks `Int`, so this
            // conversion succeeds for production rows. A non-numeric
            // value reaches here only via a tampered Codable round-trip
            // or a future Cliniko shape change — surface as
            // `.patientIDMalformed` rather than crash.
            state = .failed(.sessionState(.patientIDMalformed))
            logger.error("ExportFlowViewModel: confirm blocked — patientID malformed")
            return
        }
        guard let notes = sessionStore.active?.draftNotes else {
            state = .failed(.sessionState(.noDraftNotes))
            logger.error("ExportFlowViewModel: confirm blocked — no draft notes")
            return
        }

        // Mirror the patientIDMalformed guard for the appointment
        // boundary. Cliniko's `Appointment.id` is documented as
        // `string($int64)` (post-#129); in practice every tenant emits
        // numeric strings and `Int(rawValue)` succeeds. A non-numeric
        // value reaches here only via a tampered Codable round-trip
        // or a future Cliniko shape change — surface as
        // `.appointmentIDMalformed` rather than silently degrading
        // the export to a general note (which would lose the
        // appointment linkage with no user-visible signal).
        if case .appointment(let opaqueID) = summary.appointment,
           Int(opaqueID.rawValue) == nil {
            state = .failed(.sessionState(.appointmentIDMalformed))
            logger.error("ExportFlowViewModel: confirm blocked — appointmentID malformed")
            return
        }

        state = .uploading
        let appointmentInt = summary.appointment.wireAppointmentID
        let exporter = dependencies.exporter
        logger.info("ExportFlowViewModel: state=uploading appointmentBound=\(appointmentInt != nil ? "true" : "false", privacy: .public)")

        let task = Task { [weak self] in
            do {
                let outcome = try await exporter.export(
                    notes: notes,
                    patientID: patientIDInt,
                    appointmentID: appointmentInt
                )
                await self?.handleSuccess(outcome)
            } catch {
                await self?.handleFailure(error)
            }
        }
        uploadTask = task
        deinitUploadTask = task
    }

    /// Cancel the export sheet. From `.confirming` this is a clean
    /// dismiss — the host closes the sheet, no state on Cliniko
    /// changed. From `.uploading` we **deliberately do not cancel
    /// the in-flight POST** because POST is non-idempotent: a
    /// cancel after the bytes left the wire creates the same
    /// "did the note land?" ambiguity as a transport timeout. The
    /// view disables Cancel during `.uploading`; this is a
    /// defensive no-op.
    func cancelFromConfirming() {
        guard case .confirming = state else { return }
        uploadTask?.cancel()
        uploadTask = nil
        deinitUploadTask = nil
        countdownTask?.cancel()
        countdownTask = nil
        deinitCountdownTask = nil
        state = .idle
        logger.info("ExportFlowViewModel: state=idle (user cancel from confirming)")
    }

    /// User-confirmed retry from the `.failed` state. Re-runs the
    /// upload with the same payload. Gated by the rate-limit
    /// countdown — calls during the countdown are no-ops.
    func retry() {
        guard case .failed(let reason) = state else { return }
        // Rate-limit countdown gates retry until the timer expires.
        if case .rateLimited = reason, let remaining = rateLimitCountdownRemaining, remaining > 0 {
            logger.info("ExportFlowViewModel: retry gated — rate-limit countdown active remaining=\(Int(remaining), privacy: .public)")
            return
        }
        // Retry routes back through `enterConfirming` so the summary
        // is recomputed in case the session state shifted (e.g. a
        // dropped manipulation became valid again because the
        // taxonomy reloaded).
        rateLimitCountdownRemaining = nil
        countdownTask?.cancel()
        countdownTask = nil
        deinitCountdownTask = nil
        enterConfirming()
        // If the recomputed summary is .confirming and the
        // appointment was previously resolved, auto-confirm so the
        // retry looks like a single button click rather than a
        // round-trip through the confirmation step.
        if case .confirming(let summary) = state, summary.appointment.isResolved {
            confirm()
        }
    }

    /// Open the Cliniko credentials surface. Wired by the host
    /// to `MainWindowController.shared.showSection(.clinicalNotes)`.
    func openClinikoSettings() {
        dependencies.openClinikoSettings()
        logger.info("ExportFlowViewModel: opened Cliniko settings")
    }

    /// Copy the composed SOAP body to the system clipboard so the
    /// practitioner has a paper-or-other-app fallback when the
    /// network is offline. The clipboard payload is the same wire
    /// body Cliniko would have received.
    ///
    /// PHI: this is the one path inside the export flow that
    /// surfaces SOAP content out of the in-memory session. It only
    /// fires from a deliberate user action ("Copy to clipboard"
    /// button on the failed-transport surface) and does not write
    /// to disk or to OSLog. The clipboard is user-scoped on macOS
    /// and the practitioner is the sole audience.
    func copyNoteToClipboard() {
        guard let notes = sessionStore.active?.draftNotes else { return }
        let body = TreatmentNotePayload.composeNotesBody(
            notes: notes,
            manipulations: dependencies.manipulations
        ).body
        dependencies.copyToClipboard(body)
        logger.info("ExportFlowViewModel: copied SOAP body to clipboard length=\(body.count, privacy: .public)")
    }

    // MARK: - Private

    private func buildSummary() -> Result<ExportSummary, ExportFailure> {
        guard let active = sessionStore.active else {
            return .failure(.sessionState(.noActiveSession))
        }
        guard let patientID = active.selectedPatientID else {
            return .failure(.sessionState(.noPatient))
        }
        let notes = active.draftNotes ?? StructuredNotes()
        let composed = TreatmentNotePayload.composeNotesBody(
            notes: notes,
            manipulations: dependencies.manipulations
        )
        let resolvedManipulations: [String] = notes.selectedManipulationIDs.compactMap { id in
            dependencies.manipulations.all.first { $0.id == id }?.displayName
        }
        let sectionCounts: [ExportSummary.SectionCount] = SOAPField.allCases.map { field in
            ExportSummary.SectionCount(
                field: field,
                charCount: notes[keyPath: field.notesKeyPath].count
            )
        }
        let initialSelection: AppointmentSelection
        if let appointmentID = active.selectedAppointmentID {
            initialSelection = .appointment(appointmentID)
        } else {
            // The picker writethrough nils the appointment when a
            // new patient is selected; that's distinct from "the
            // practitioner explicitly chose no appointment". Start
            // in `.unset` so the confirm gate fires and forces the
            // practitioner to make a choice on this screen.
            initialSelection = .unset
        }
        let summary = ExportSummary(
            patientID: patientID,
            patientDisplayName: active.selectedPatientDisplayName ?? "Selected patient",
            appointment: initialSelection,
            sectionCounts: sectionCounts,
            resolvedManipulations: resolvedManipulations,
            droppedManipulationIDs: composed.droppedManipulationIDs,
            excludedNotExportedCount: notes.excluded.count - active.excludedReAdded.count
        )
        return .success(summary)
    }

    private func handleSuccess(_ outcome: TreatmentNoteExporter.ExportOutcome) {
        uploadTask = nil
        deinitUploadTask = nil
        let report = SuccessReport(
            createdNoteID: OpaqueClinikoID(outcome.created.id),
            auditPersisted: outcome.auditPersisted,
            droppedManipulationIDs: outcome.droppedManipulationIDs
        )
        state = .succeeded(report)
        logger.info("ExportFlowViewModel: state=succeeded auditPersisted=\(outcome.auditPersisted, privacy: .public) dropped=\(outcome.droppedManipulationIDs.count, privacy: .public)")
        // Host runs the SessionStore.clear() + window close. Caller
        // contract: `onSuccess` is the only side-effect post-success;
        // the audit row is already on disk by this point.
        dependencies.onSuccess()
    }

    private func handleFailure(_ error: Error) {
        uploadTask = nil
        deinitUploadTask = nil
        let translated = Self.translate(error)
        state = .failed(translated)
        // Structural log: the case name only. Never the URL, never
        // the body, never any field values.
        logger.error("ExportFlowViewModel: state=failed reason=\(Self.caseName(translated), privacy: .public)")
        if case .rateLimited(let retryAfter) = translated {
            startRateLimitCountdown(seconds: retryAfter ?? 60)
        }
    }

    private func startRateLimitCountdown(seconds: TimeInterval) {
        countdownTask?.cancel()
        let initial = max(0, seconds)
        rateLimitCountdownRemaining = initial
        let task = Task { [weak self] in
            var remaining = initial
            while remaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                remaining -= 1
                await self?.updateCountdown(remaining)
            }
        }
        countdownTask = task
        deinitCountdownTask = task
    }

    private func updateCountdown(_ remaining: TimeInterval) {
        rateLimitCountdownRemaining = max(0, remaining)
    }

    // MARK: - Translate errors

    /// Convert any thrown `Error` into a UI-shaped `ExportFailure`.
    /// Order matters — `TreatmentNoteExporter.Failure` cases must
    /// match before the `ClinikoError` arm to avoid a wider catch.
    ///
    /// `cyclomatic_complexity` is silenced on this switch (see
    /// trailing-comment annotation) because `ClinikoError` has 10
    /// cases and `TreatmentNoteExporter.Failure` adds two more —
    /// splitting the function would push the same switch elsewhere
    /// and break the colocation that makes the translation table
    /// easy to read.
    static func translate(_ error: Error) -> ExportFailure { // swiftlint:disable:this cyclomatic_complexity
        if let exporterFailure = error as? TreatmentNoteExporter.Failure {
            switch exporterFailure {
            case .responseUndecodable: return .responseUndecodable
            case .requestEncodeFailed: return .requestEncodeFailed
            }
        }
        if let clinikoError = error as? ClinikoError {
            switch clinikoError {
            case .unauthenticated: return .unauthenticated
            case .forbidden: return .forbidden
            case .notFound(let resource): return .notFound(resource: resource)
            case .validation(let fields): return .validation(fields: fields)
            case .rateLimited(let retryAfter): return .rateLimited(retryAfter: retryAfter)
            case .server(let status): return .server(status: status)
            case .transport(let code): return .transport(code)
            case .cancelled: return .cancelled
            case .decoding(let typeName): return .decoding(typeName: typeName)
            case .nonHTTPResponse: return .transport(.unknown)
            }
        }
        if error is CancellationError {
            return .cancelled
        }
        // Unknown error class — surface as a transport-shaped
        // failure so the UI offers retry + clipboard. Logged
        // structurally above.
        return .transport(.unknown)
    }

    /// Structural label for an `ExportFailure` case — used only for
    /// log lines (`privacy: .public`). Never includes payload
    /// values (no validation field names, no URLError code raw
    /// values).
    ///
    /// `cyclomatic_complexity` silenced for the same reason as
    /// `translate(_:)`.
    static func caseName(_ failure: ExportFailure) -> String { // swiftlint:disable:this cyclomatic_complexity
        switch failure {
        case .unauthenticated: return "unauthenticated"
        case .forbidden: return "forbidden"
        case .notFound: return "notFound"
        case .validation: return "validation"
        case .rateLimited: return "rateLimited"
        case .server: return "server"
        case .transport: return "transport"
        case .responseUndecodable: return "responseUndecodable"
        case .requestEncodeFailed: return "requestEncodeFailed"
        case .cancelled: return "cancelled"
        case .decoding: return "decoding"
        case .sessionState(let inner):
            switch inner {
            case .noActiveSession: return "sessionState.noActiveSession"
            case .noPatient: return "sessionState.noPatient"
            case .patientIDMalformed: return "sessionState.patientIDMalformed"
            case .appointmentIDMalformed: return "sessionState.appointmentIDMalformed"
            case .appointmentUnresolved: return "sessionState.appointmentUnresolved"
            case .noDraftNotes: return "sessionState.noDraftNotes"
            }
        }
    }
}
