import Foundation
import Testing
@testable import SpeechToText

// MARK: - SessionStore lifecycle tests
//
// Covers issue #2 acceptance criteria:
//   - start/replace/clear lifecycle
//   - mutator no-op semantics when active == nil
//   - idle-timeout behaviour driven by an injected clock
//   - PHI-free-disk invariant (no writes to UserDefaults)
//
// Style: Swift Testing only; every test tagged `.fast` via the suite. The
// suite is `@MainActor` because `SessionStore` is MainActor-isolated.
// See `.claude/references/phi-handling.md` for the PHI policy and
// `Tests/SpeechToTextTests/Utilities/SwiftTestingExemplarTests.swift`
// for the canonical idiom.

@Suite("SessionStore", .tags(.fast))
@MainActor
struct SessionStoreTests {

    // MARK: - Helpers

    /// Build a mutable clock whose value can be advanced between calls.
    /// Returned closure is `@Sendable` to satisfy `SessionStore.init`.
    private final class MutableClock: @unchecked Sendable {
        var current: Date
        init(_ start: Date) { self.current = start }
    }

    private func makeClock(_ start: Date = Date(timeIntervalSince1970: 1_000_000))
        -> (MutableClock, @Sendable () -> Date) {
        let box = MutableClock(start)
        let closure: @Sendable () -> Date = { box.current }
        return (box, closure)
    }

    // MARK: - start(from:)

    @Test("start(from:) activates a session and stamps lastActivity")
    func start_fromRecording_activates() {
        let (clock, now) = makeClock()
        let store = SessionStore(now: now)
        let recording = RecordingSession()

        store.start(from: recording)

        #expect(store.active != nil)
        #expect(store.active?.recordingSession.id == recording.id)
        #expect(store.lastActivity == clock.current)
    }

    // MARK: - start(_:)

    @Test("start(_:) with a pre-built session round-trips every field")
    func start_preBuilt_roundTrips() throws {
        let store = SessionStore()
        let notes = StructuredNotes(subjective: "subjective-placeholder")
        let id = UUID()
        let patientID = OpaqueClinikoID(rawValue: "patient-1")
        let appointmentID = OpaqueClinikoID(rawValue: "appt-1")
        let session = ClinicalSession(
            id: id,
            recordingSession: RecordingSession(),
            draftNotes: notes,
            excludedReAdded: ["snippet-placeholder"],
            selectedPatientID: patientID,
            selectedAppointmentID: appointmentID
        )

        store.start(session)

        let active = try #require(store.active)
        #expect(active.id == id)
        #expect(active.draftNotes == notes)
        #expect(active.excludedReAdded == ["snippet-placeholder"])
        #expect(active.selectedPatientID == patientID)
        #expect(active.selectedAppointmentID == appointmentID)
    }

    // MARK: - replace

    @Test("start replaces the previously active session")
    func start_replacesPreviousSession() throws {
        let store = SessionStore()
        store.start(from: RecordingSession())
        let firstID = try #require(store.active?.id)

        store.start(from: RecordingSession())
        let secondID = try #require(store.active?.id)

        #expect(firstID != secondID)
    }

    // MARK: - clear

    @Test("clear() drops the active session")
    func clear_dropsActive() {
        let store = SessionStore()
        store.start(from: RecordingSession())

        store.clear()

        #expect(store.active == nil)
    }

    @Test("clear() is idempotent when nothing is active")
    func clear_idempotent() {
        let store = SessionStore()
        store.clear()
        store.clear()
        #expect(store.active == nil)
    }

    // MARK: - Mutators when inactive

    @Test("setDraftNotes is a no-op when active is nil")
    func setDraftNotes_noopWhenInactive() {
        let store = SessionStore()
        store.setDraftNotes(StructuredNotes(subjective: "subjective-placeholder"))
        #expect(store.active == nil)
    }

    @Test("markExcludedReAdded is a no-op when active is nil")
    func markExcludedReAdded_noopWhenInactive() {
        let store = SessionStore()
        store.markExcludedReAdded("snippet-placeholder")
        #expect(store.active == nil)
    }

    @Test("setSelectedPatient is a no-op when active is nil")
    func setSelectedPatient_noopWhenInactive() {
        let store = SessionStore()
        store.setSelectedPatient(id: OpaqueClinikoID(rawValue: "patient-1"))
        #expect(store.active == nil)
    }

    @Test("setSelectedAppointment is a no-op when active is nil")
    func setSelectedAppointment_noopWhenInactive() {
        let store = SessionStore()
        store.setSelectedAppointment(id: OpaqueClinikoID(rawValue: "appt-1"))
        #expect(store.active == nil)
    }

    // MARK: - setDraftNotes

    @Test("setDraftNotes updates the active session")
    func setDraftNotes_updatesActive() {
        let store = SessionStore()
        store.start(from: RecordingSession())
        let notes = StructuredNotes(subjective: "subjective-placeholder")

        store.setDraftNotes(notes)

        #expect(store.active?.draftNotes == notes)
    }

    // MARK: - markExcludedReAdded

    @Test("markExcludedReAdded appends on first call")
    func markExcludedReAdded_appends() {
        let store = SessionStore()
        store.start(from: RecordingSession())

        store.markExcludedReAdded("snippet-1")

        #expect(store.active?.excludedReAdded == ["snippet-1"])
    }

    @Test("markExcludedReAdded dedups identical entries")
    func markExcludedReAdded_dedups() {
        let store = SessionStore()
        store.start(from: RecordingSession())

        store.markExcludedReAdded("snippet-1")
        store.markExcludedReAdded("snippet-1")

        #expect(store.active?.excludedReAdded == ["snippet-1"])
    }

    @Test("markExcludedReAdded preserves order across distinct entries")
    func markExcludedReAdded_preservesOrder() {
        let store = SessionStore()
        store.start(from: RecordingSession())

        store.markExcludedReAdded("snippet-a")
        store.markExcludedReAdded("snippet-b")
        store.markExcludedReAdded("snippet-c")

        #expect(store.active?.excludedReAdded == ["snippet-a", "snippet-b", "snippet-c"])
    }

    // MARK: - setSelectedPatient / setSelectedAppointment

    @Test("setSelectedPatient round-trips and clears on nil")
    func setSelectedPatient_roundTrips() {
        let store = SessionStore()
        store.start(from: RecordingSession())

        let patientID = OpaqueClinikoID(rawValue: "patient-1")
        store.setSelectedPatient(id: patientID)
        #expect(store.active?.selectedPatientID == patientID)

        store.setSelectedPatient(id: nil)
        #expect(store.active?.selectedPatientID == nil)
    }

    @Test("setSelectedAppointment round-trips and clears on nil")
    func setSelectedAppointment_roundTrips() {
        let store = SessionStore()
        store.start(from: RecordingSession())

        let appointmentID = OpaqueClinikoID(rawValue: "appt-1")
        store.setSelectedAppointment(id: appointmentID)
        #expect(store.active?.selectedAppointmentID == appointmentID)

        store.setSelectedAppointment(id: nil)
        #expect(store.active?.selectedAppointmentID == nil)
    }

    // MARK: - touch()

    @Test("touch() bumps lastActivity to the injected clock's latest value")
    func touch_bumpsLastActivity() {
        let (clock, now) = makeClock()
        let store = SessionStore(now: now)
        let initialStamp = store.lastActivity

        clock.current = clock.current.addingTimeInterval(42)
        store.touch()

        #expect(store.lastActivity != initialStamp)
        #expect(store.lastActivity == clock.current)
    }

    // MARK: - checkIdleTimeout()

    @Test("checkIdleTimeout returns false when no session is active")
    func checkIdleTimeout_falseWhenInactive() {
        let store = SessionStore()
        #expect(store.checkIdleTimeout() == false)
    }

    @Test("checkIdleTimeout returns false when elapsed < idleTimeout")
    func checkIdleTimeout_falseWhenBelowThreshold() {
        let (clock, now) = makeClock()
        let store = SessionStore(idleTimeout: 60, now: now)
        store.start(from: RecordingSession())

        clock.current = clock.current.addingTimeInterval(30)

        #expect(store.checkIdleTimeout() == false)
        #expect(store.active != nil)
    }

    @Test("checkIdleTimeout returns false at exactly elapsed == idleTimeout (strict >)")
    func checkIdleTimeout_falseAtBoundary() {
        let (clock, now) = makeClock()
        let store = SessionStore(idleTimeout: 60, now: now)
        store.start(from: RecordingSession())

        clock.current = clock.current.addingTimeInterval(60)

        #expect(store.checkIdleTimeout() == false)
        #expect(store.active != nil)
    }

    @Test("checkIdleTimeout clears and returns true when elapsed > idleTimeout")
    func checkIdleTimeout_clearsWhenExceeded() {
        let (clock, now) = makeClock()
        let store = SessionStore(idleTimeout: 60, now: now)
        store.start(from: RecordingSession())

        clock.current = clock.current.addingTimeInterval(61)

        #expect(store.checkIdleTimeout() == true)
        #expect(store.active == nil)
    }

    @Test("checkIdleTimeout returns false on a second call after a successful clear")
    func checkIdleTimeout_secondCallFalseAfterClear() {
        let (clock, now) = makeClock()
        let store = SessionStore(idleTimeout: 60, now: now)
        store.start(from: RecordingSession())

        clock.current = clock.current.addingTimeInterval(61)
        _ = store.checkIdleTimeout()

        #expect(store.checkIdleTimeout() == false)
    }

    // MARK: - PHI-free disk invariant

    @Test("SessionStore lifecycle writes nothing to UserDefaults")
    func lifecycle_doesNotTouchUserDefaults() {
        let before = UserDefaults.standard.dictionaryRepresentation()
        let beforeKeys = Set(before.keys)

        // Exercise the full public surface.
        let store = SessionStore()
        store.start(from: RecordingSession())
        store.setDraftNotes(StructuredNotes(subjective: "subjective-placeholder"))
        store.markExcludedReAdded("snippet-placeholder")
        store.setSelectedPatient(id: OpaqueClinikoID(rawValue: "patient-1"))
        store.setSelectedAppointment(id: OpaqueClinikoID(rawValue: "appt-1"))
        store.touch()
        _ = store.checkIdleTimeout()
        store.clear()

        let after = UserDefaults.standard.dictionaryRepresentation()
        let afterKeys = Set(after.keys)

        #expect(beforeKeys == afterKeys)
        for key in beforeKeys {
            #expect(
                String(describing: before[key]) == String(describing: after[key]),
                "UserDefaults value for \(key) changed during SessionStore lifecycle"
            )
        }
    }

    // MARK: - Export-success contract

    @Test("Export-success path: populated session clears to nil")
    func exportSuccess_clearsActive() {
        let store = SessionStore()
        store.start(from: RecordingSession())
        store.setDraftNotes(StructuredNotes(
            subjective: "subjective-placeholder",
            objective: "objective-placeholder",
            assessment: "assessment-placeholder",
            plan: "plan-placeholder"
        ))
        store.setSelectedPatient(id: OpaqueClinikoID(rawValue: "patient-1"))
        store.setSelectedAppointment(id: OpaqueClinikoID(rawValue: "appt-1"))

        store.clear()

        #expect(store.active == nil)
    }
}
