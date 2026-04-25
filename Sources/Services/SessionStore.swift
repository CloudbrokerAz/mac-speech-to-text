import Foundation
import Observation

/// Owns the in-memory lifecycle of a single `ClinicalSession`.
///
/// There is exactly one active session at a time — from the completion of
/// a `RecordingSession` through LLM generation, practitioner review, and
/// Cliniko export. `clear()` drops the active session; callers are
/// expected to invoke it on:
///   - successful `treatment_note` export (#10),
///   - app termination / `NSApplication.willTerminateNotification`,
///   - user-initiated cancel,
///   - `checkIdleTimeout()` crossing the inactivity threshold.
///
/// **PHI.** Everything on the active session is patient data (transcript,
/// draft SOAP note, patient/appointment IDs). This type therefore writes
/// nothing to disk, `UserDefaults`, or logs. See
/// `.claude/references/phi-handling.md`.
///
/// Thread safety:
/// - `@MainActor`-isolated so SwiftUI views can observe `active` without
///   actor hops.
/// - No `@ObservationIgnored` dependencies today; if this store ever
///   gains an `any SomeActor`-typed collaborator, it must be marked
///   `@ObservationIgnored` (see `.claude/references/concurrency.md` §1).
@Observable
@MainActor
final class SessionStore {
    // MARK: - Observed state

    /// The currently-active session, or `nil` if nothing is in flight.
    private(set) var active: ClinicalSession?

    /// Timestamp of the most recent mutation to `active`. Used by
    /// `checkIdleTimeout()`.
    private(set) var lastActivity: Date

    // MARK: - Dependencies

    /// Injectable clock. Defaults to `Date.init`. Tests pass a
    /// fake to drive `checkIdleTimeout` deterministically.
    @ObservationIgnored private let now: @Sendable () -> Date

    /// How long `active` may sit unmodified before `checkIdleTimeout()`
    /// discards it. Default 30 minutes.
    @ObservationIgnored private let idleTimeout: TimeInterval

    // MARK: - Initialisation

    init(
        idleTimeout: TimeInterval = 30 * 60,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.idleTimeout = idleTimeout
        self.now = now
        self.lastActivity = now()
    }

    // MARK: - Lifecycle

    /// Start a new session from a completed `RecordingSession`.
    /// Replaces any currently-active session.
    func start(from recording: RecordingSession) {
        let session = ClinicalSession(recordingSession: recording)
        active = session
        touch()
        AppLogger.service.info("SessionStore: started session")
    }

    /// Start from a pre-built `ClinicalSession`. Primarily used by tests
    /// so they can set up a populated session without driving it through
    /// the `setDraftNotes` / `setSelectedPatient` mutators one at a time.
    /// Not currently used in production.
    func start(_ session: ClinicalSession) {
        active = session
        touch()
        AppLogger.service.info("SessionStore: started session")
    }

    /// Discard the active session. Idempotent.
    ///
    /// Call sites: successful export, app quit, cancel, idle timeout.
    func clear() {
        guard active != nil else { return }
        active = nil
        touch()
        AppLogger.service.info("SessionStore: cleared session")
    }

    // MARK: - Mutations

    /// Attach or replace the LLM-generated SOAP draft.
    func setDraftNotes(_ notes: StructuredNotes?) {
        guard active != nil else { return }
        active?.draftNotes = notes
        touch()
    }

    /// Record that the practitioner re-added a previously-excluded
    /// snippet. Duplicates are ignored.
    func markExcludedReAdded(_ snippet: String) {
        guard let current = active?.excludedReAdded, !current.contains(snippet) else { return }
        active?.excludedReAdded.append(snippet)
        touch()
    }

    /// Set the Cliniko patient selection. The `OpaqueClinikoID` type
    /// tag (#59) means callers can't accidentally pass in a free-form
    /// string — they must construct from a numeric `Patient.id` (the
    /// Cliniko-response shape) or from a `rawValue` string with a
    /// documented provenance (Codable round-trip, test wiring).
    func setSelectedPatient(id: OpaqueClinikoID?) {
        guard active != nil else { return }
        active?.selectedPatientID = id
        touch()
    }

    /// Set the Cliniko appointment selection. Same `OpaqueClinikoID`
    /// type-tag invariant as `setSelectedPatient(id:)` — the picker
    /// constructs from the numeric `Appointment.id`; tests use
    /// `init(rawValue:)` for deterministic literals.
    func setSelectedAppointment(id: OpaqueClinikoID?) {
        guard active != nil else { return }
        active?.selectedAppointmentID = id
        touch()
    }

    // MARK: - Idle management

    /// Bumps `lastActivity` to "now". Called from every mutation above.
    /// Exposed so the UI layer can surface activity (e.g. focus change in
    /// the ReviewScreen) without mutating the session itself.
    func touch() {
        lastActivity = now()
    }

    /// Host-callable inactivity check. If `now() - lastActivity` exceeds
    /// `idleTimeout`, discards the active session.
    ///
    /// This store deliberately does not own a timer — the app lifecycle
    /// (e.g. `NSApplication.willResignActive`) drives invocation so tests
    /// stay deterministic and we avoid coupling the PHI layer to a
    /// run-loop.
    @discardableResult
    func checkIdleTimeout() -> Bool {
        guard active != nil else { return false }
        let elapsed = now().timeIntervalSince(lastActivity)
        guard elapsed > idleTimeout else { return false }
        AppLogger.service.info("SessionStore: idle timeout exceeded, clearing session")
        active = nil
        lastActivity = now()
        return true
    }
}
