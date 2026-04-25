import Foundation
import Testing
@testable import SpeechToText

// MARK: - ClinicalSession model tests
//
// Pure-logic invariants only. `SessionStore` (see SessionStoreTests) covers
// the lifecycle + PHI-free-disk assertions.

@Suite("ClinicalSession", .tags(.fast))
struct ClinicalSessionTests {

    @Test("Default init populates defaults and generates an id")
    func init_defaults() {
        let recording = RecordingSession()
        let session = ClinicalSession(recordingSession: recording)

        #expect(session.recordingSession.id == recording.id)
        #expect(session.draftNotes == nil)
        #expect(session.excludedReAdded.isEmpty)
        #expect(session.selectedPatientID == nil)
        #expect(session.selectedAppointmentID == nil)
    }

    @Test("IDs are distinct across sessions built from the same recording")
    func init_idsAreDistinct() {
        let recording = RecordingSession()
        let a = ClinicalSession(recordingSession: recording)
        let b = ClinicalSession(recordingSession: recording)
        #expect(a.id != b.id)
    }

    @Test("Full-init round-trips every field")
    func init_full() {
        let recording = RecordingSession()
        let notes = StructuredNotes(
            subjective: "s",
            objective: "o",
            assessment: "a",
            plan: "p",
            selectedManipulationIDs: ["diversified"],
            excluded: ["smalltalk"]
        )
        let id = UUID()
        let patientID = OpaqueClinikoID(rawValue: "patient-1")
        let appointmentID = OpaqueClinikoID(rawValue: "appt-1")
        let session = ClinicalSession(
            id: id,
            recordingSession: recording,
            draftNotes: notes,
            excludedReAdded: ["weather"],
            selectedPatientID: patientID,
            selectedAppointmentID: appointmentID
        )

        #expect(session.id == id)
        #expect(session.draftNotes == notes)
        #expect(session.excludedReAdded == ["weather"])
        #expect(session.selectedPatientID == patientID)
        #expect(session.selectedAppointmentID == appointmentID)
    }

    @Test("Mutating draftNotes leaves other fields untouched")
    func mutate_draftNotesIsIsolated() {
        let patientID = OpaqueClinikoID(rawValue: "p")
        var session = ClinicalSession(
            recordingSession: RecordingSession(),
            selectedPatientID: patientID
        )
        session.draftNotes = StructuredNotes(subjective: "x")

        #expect(session.draftNotes?.subjective == "x")
        #expect(session.selectedPatientID == patientID)
    }
}

@Suite("StructuredNotes", .tags(.fast))
struct StructuredNotesTests {
    @Test("Default init is empty")
    func init_defaults() {
        let notes = StructuredNotes()
        #expect(notes.subjective.isEmpty)
        #expect(notes.objective.isEmpty)
        #expect(notes.assessment.isEmpty)
        #expect(notes.plan.isEmpty)
        #expect(notes.selectedManipulationIDs.isEmpty)
        #expect(notes.excluded.isEmpty)
    }

    @Test("Equatable distinguishes field changes")
    func equatable_detectsChanges() {
        let base = StructuredNotes(subjective: "a")
        var mutated = base
        mutated.subjective = "b"
        #expect(base != mutated)
    }

    @Test("Equatable discriminates on manipulations and excluded arrays")
    func equatable_discriminatesOnArrayFields() {
        let base = StructuredNotes(selectedManipulationIDs: ["a"], excluded: ["x"])

        var differentManipulations = base
        differentManipulations.selectedManipulationIDs = ["a", "b"]
        #expect(base != differentManipulations)

        var differentExcluded = base
        differentExcluded.excluded = ["y"]
        #expect(base != differentExcluded)

        var sameShape = base
        sameShape.selectedManipulationIDs = ["a"]
        sameShape.excluded = ["x"]
        #expect(base == sameShape)
    }
}
