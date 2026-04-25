import Foundation

/// JSON payload posted to `POST /treatment_notes` and the matching
/// response shape we decode the 201 body into.
///
/// **Issue #10.** The wire shape pinned here is the v1 contract; updating
/// it requires a paired update of
/// `Tests/SpeechToTextTests/Fixtures/cliniko/requests/treatment_notes_create.json`
/// + `responses/treatment_notes_create.json`.
///
/// ## Tenant-template variability
///
/// Per `.claude/references/cliniko-api.md` §"Tenant template variability",
/// v1 ships the SOAP note as a single markdown body (`notes`) plus the
/// resource IDs. Per-template custom-field mapping is deferred — once a
/// real clinic supplies its template definition, the mapping lives in a
/// follow-up exporter strategy, not in this struct.
///
/// ## PHI
///
/// `notes` is patient data. The struct itself is `Sendable`, but every
/// instance is short-lived: built immediately before the POST and dropped
/// once the request returns. `description` / `debugDescription` are
/// **not** customised — never log a `TreatmentNotePayload`; the
/// `ClinikoClient` body-redaction contract (`.claude/references/cliniko-api.md`
/// §Redaction) is what protects the payload at the network layer.
public struct TreatmentNotePayload: Codable, Sendable, Equatable {
    /// Cliniko numeric patient ID (the resource the note attaches to).
    public let patientID: Int

    /// Optional Cliniko appointment ID. Present when the practitioner
    /// picked a specific appointment in the picker; `nil` when they
    /// chose to attach to the patient only.
    public let appointmentID: Int?

    /// Markdown body composed from the practitioner-edited SOAP draft +
    /// selected manipulations. Excluded snippets are NOT included.
    /// Build via `composeNotesBody(notes:manipulations:)` so the format
    /// stays consistent across call sites and tests.
    public let notes: String

    public init(patientID: Int, appointmentID: Int?, notes: String) {
        self.patientID = patientID
        self.appointmentID = appointmentID
        self.notes = notes
    }

    /// Explicit snake_case keys instead of `keyEncodingStrategy =
    /// .convertToSnakeCase` so the wire shape can't drift if a future
    /// caller swaps in a differently-configured encoder.
    private enum CodingKeys: String, CodingKey {
        case patientID = "patient_id"
        case appointmentID = "appointment_id"
        case notes
    }
}

extension TreatmentNotePayload {
    /// Output of `composeNotesBody`. Carries the markdown body plus a
    /// list of manipulation IDs that the practitioner had selected but
    /// which are not present in the taxonomy (e.g. after a placeholder-
    /// to-real-taxonomy swap that removed an entry). The body itself
    /// silently omits those IDs — surfacing the dropped list separately
    /// lets the export-flow UI (#14) decide whether to confirm-before-
    /// send. **Never** appears in logs or `audit.jsonl`; surfaced only
    /// to the in-process caller.
    struct ComposedNotes: Equatable, Sendable {
        let body: String
        let droppedManipulationIDs: [String]
    }

    /// Compose the markdown body Cliniko receives. Section headers are
    /// emitted only for SOAP fields with non-empty trimmed content; the
    /// Manipulations section is appended only when at least one selected
    /// ID resolves into the taxonomy. Excluded snippets are never
    /// emitted (the practitioner already saw them in the ReviewScreen
    /// drawer).
    ///
    /// Format (markdown, two-line section breaks):
    /// ```
    /// ## Subjective
    /// <text>
    ///
    /// ## Objective
    /// <text>
    /// ...
    ///
    /// ## Manipulations
    /// - Diversified HVLA
    /// - Drop-Table Technique
    /// ```
    ///
    /// Manipulation order follows the practitioner's selection order in
    /// `notes.selectedManipulationIDs` — not alphabetical, not the
    /// repository's display order — so the wire shape mirrors what the
    /// practitioner saw on screen. Selections that don't resolve into
    /// `manipulations.all` (stale ID after a taxonomy swap) are dropped
    /// from the body **and** returned in `droppedManipulationIDs` so the
    /// caller can warn the practitioner.
    static func composeNotesBody(
        notes: StructuredNotes,
        manipulations: ManipulationsRepository
    ) -> ComposedNotes {
        var sections: [String] = []

        for (heading, value) in [
            ("Subjective", notes.subjective),
            ("Objective", notes.objective),
            ("Assessment", notes.assessment),
            ("Plan", notes.plan)
        ] {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            sections.append("## \(heading)\n\(trimmed)")
        }

        let lookup = Dictionary(uniqueKeysWithValues: manipulations.all.map { ($0.id, $0) })
        var resolvedNames: [String] = []
        var dropped: [String] = []
        for id in notes.selectedManipulationIDs {
            if let manipulation = lookup[id] {
                resolvedNames.append(manipulation.displayName)
            } else {
                dropped.append(id)
            }
        }
        if !resolvedNames.isEmpty {
            let bullets = resolvedNames.map { "- \($0)" }.joined(separator: "\n")
            sections.append("## Manipulations\n\(bullets)")
        }

        return ComposedNotes(
            body: sections.joined(separator: "\n\n"),
            droppedManipulationIDs: dropped
        )
    }
}

/// Subset of the `treatment_notes` 201 response body the exporter cares
/// about. Cliniko returns the full created object; we decode only the
/// numeric `id` because (a) every other field is the SOAP body the
/// practitioner already has in memory, and (b) `AuditStore` records
/// `note_id` from this value.
///
/// Decodes via `ClinikoClient.defaultDecoder` (snake_case → camelCase),
/// so the wire `"id"` survives unchanged.
public struct TreatmentNoteCreated: Decodable, Sendable, Equatable {
    public let id: Int

    public init(id: Int) {
        self.id = id
    }
}
