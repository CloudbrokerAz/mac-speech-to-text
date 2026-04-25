import Foundation
import Testing
@testable import SpeechToText

/// Pure-logic tests for the Cliniko `treatment_note` wire payload — body
/// composition + golden-fixture round-trip. Network behaviour lives in
/// `TreatmentNoteExporterTests`.
@Suite("TreatmentNotePayload", .tags(.fast))
struct TreatmentNotePayloadTests {
    private static let manipulations = ManipulationsRepository(all: [
        Manipulation(id: "diversified_hvla", displayName: "Diversified HVLA", clinikoCode: nil),
        Manipulation(id: "drop_table", displayName: "Drop-Table Technique", clinikoCode: nil),
        Manipulation(id: "thompson", displayName: "Thompson Drop-Table", clinikoCode: nil)
    ])

    // MARK: - composeNotesBody

    @Test("Includes every populated SOAP section in S/O/A/P order")
    func composeNotesBody_emitsAllPopulatedSoapSections() {
        let notes = StructuredNotes(
            subjective: "Subj text.",
            objective: "Obj text.",
            assessment: "Asmt text.",
            plan: "Plan text."
        )

        let composed = TreatmentNotePayload.composeNotesBody(notes: notes, manipulations: Self.manipulations)

        let expected = """
        ## Subjective
        Subj text.

        ## Objective
        Obj text.

        ## Assessment
        Asmt text.

        ## Plan
        Plan text.
        """
        #expect(composed.body == expected)
        #expect(composed.droppedManipulationIDs.isEmpty)
    }

    @Test("Omits SOAP sections whose value is empty or whitespace-only")
    func composeNotesBody_dropsEmptySoapSections() {
        let notes = StructuredNotes(
            subjective: "Only subjective populated.",
            objective: "",
            assessment: "   \n  ",
            plan: ""
        )

        let composed = TreatmentNotePayload.composeNotesBody(notes: notes, manipulations: Self.manipulations)

        #expect(composed.body == "## Subjective\nOnly subjective populated.")
    }

    @Test("Trims surrounding whitespace inside each section's value")
    func composeNotesBody_trimsSectionValues() {
        let notes = StructuredNotes(subjective: "  hello\n\n")
        let composed = TreatmentNotePayload.composeNotesBody(notes: notes, manipulations: Self.manipulations)
        #expect(composed.body == "## Subjective\nhello")
    }

    @Test("Appends Manipulations section in selection order, resolving display names")
    func composeNotesBody_appendsManipulationsInSelectionOrder() {
        let notes = StructuredNotes(
            subjective: "ok",
            // Selection order: drop_table BEFORE diversified_hvla — verify
            // the body mirrors that order, not the repository's.
            selectedManipulationIDs: ["drop_table", "diversified_hvla"]
        )

        let composed = TreatmentNotePayload.composeNotesBody(notes: notes, manipulations: Self.manipulations)

        #expect(composed.body.contains("## Manipulations\n- Drop-Table Technique\n- Diversified HVLA"))
        #expect(composed.droppedManipulationIDs.isEmpty)
    }

    @Test("Surfaces unknown manipulation IDs separately from the body")
    func composeNotesBody_surfacesUnknownManipulationIDs() {
        let notes = StructuredNotes(
            subjective: "ok",
            selectedManipulationIDs: ["diversified_hvla", "deleted_after_taxonomy_swap"]
        )

        let composed = TreatmentNotePayload.composeNotesBody(notes: notes, manipulations: Self.manipulations)

        #expect(composed.body.contains("- Diversified HVLA"))
        #expect(!composed.body.contains("deleted_after_taxonomy_swap"))
        #expect(composed.droppedManipulationIDs == ["deleted_after_taxonomy_swap"])
    }

    @Test("Omits the Manipulations section entirely when no IDs resolve")
    func composeNotesBody_omitsManipulationsSectionWhenEmpty() {
        let notes = StructuredNotes(
            subjective: "ok",
            selectedManipulationIDs: ["unknown1", "unknown2"]
        )

        let composed = TreatmentNotePayload.composeNotesBody(notes: notes, manipulations: Self.manipulations)

        #expect(!composed.body.contains("## Manipulations"))
        #expect(composed.droppedManipulationIDs == ["unknown1", "unknown2"])
    }

    @Test("Manipulations-only body emits just the Manipulations section when no SOAP populated")
    func composeNotesBody_manipulationsOnly_whenNoSoapPopulated() {
        let notes = StructuredNotes(
            // All four SOAP sections empty (matches the follow-up-visit
            // workflow where the practitioner only logs which
            // manipulations were performed).
            selectedManipulationIDs: ["diversified_hvla"]
        )

        let composed = TreatmentNotePayload.composeNotesBody(notes: notes, manipulations: Self.manipulations)

        #expect(composed.body == "## Manipulations\n- Diversified HVLA")
    }

    @Test("Never embeds excluded snippets in the wire body")
    func composeNotesBody_excludesExcludedContent() {
        let notes = StructuredNotes(
            subjective: "ok",
            excluded: ["weekend small talk", "unrelated tangent about the dog"]
        )

        let composed = TreatmentNotePayload.composeNotesBody(notes: notes, manipulations: Self.manipulations)

        #expect(!composed.body.contains("weekend small talk"))
        #expect(!composed.body.contains("unrelated tangent about the dog"))
    }

    // MARK: - Fixture round-trip

    @Test("Request fixture decodes into the canonical payload shape")
    func requestFixture_decodesIntoCanonicalShape() throws {
        let data = try HTTPStubFixture.load("cliniko/requests/treatment_notes_create.json")
        let decoded = try JSONDecoder().decode(TreatmentNotePayload.self, from: data)

        let expected = TreatmentNotePayload.composeNotesBody(
            notes: StructuredNotes(
                subjective: "Patient reports lower-back pain after gardening.",
                objective: "ROM reduced; tender at L4-L5.",
                assessment: "Mechanical low back pain.",
                plan: "Diversified HVLA + home stretching plan.",
                selectedManipulationIDs: ["diversified_hvla", "drop_table"]
            ),
            manipulations: Self.manipulations
        )

        #expect(decoded == TreatmentNotePayload(
            patientID: 1001,
            appointmentID: 5001,
            notes: expected.body
        ))
    }

    @Test("Response fixture decodes the id we audit on")
    func responseFixture_decodesNoteID() throws {
        let data = try HTTPStubFixture.load("cliniko/responses/treatment_notes_create.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601

        let created = try decoder.decode(TreatmentNoteCreated.self, from: data)

        #expect(created.id == 9876543)
    }

    @Test("Encoded payload survives decode without losing fields")
    func payload_codableRoundTrip() throws {
        let original = TreatmentNotePayload(
            patientID: 7,
            appointmentID: nil,
            notes: "## Subjective\nshort note"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TreatmentNotePayload.self, from: data)

        #expect(decoded == original)
    }

    @Test("nil appointment_id is omitted from the wire shape and decodes back to nil")
    func payload_nilAppointmentID_isOmittedFromWire() throws {
        let payload = TreatmentNotePayload(patientID: 7, appointmentID: nil, notes: "x")
        let data = try JSONEncoder().encode(payload)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        // Default `Codable` synthesis uses `encodeIfPresent` for
        // `Optional`, so the key is absent from JSON when nil. We pin
        // omit-vs-null here so a future encoder swap (or a hand-rolled
        // `encode(to:)` that calls `encode(_, forKey:)`) doesn't
        // silently flip the wire shape Cliniko sees.
        #expect(json["appointment_id"] == nil)
        #expect((json["patient_id"] as? Int) == 7)
        #expect((json["notes"] as? String) == "x")

        let roundTrip = try JSONDecoder().decode(TreatmentNotePayload.self, from: data)
        #expect(roundTrip.appointmentID == nil)
    }
}
