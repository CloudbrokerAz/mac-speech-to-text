import Foundation

/// Structured clinical note produced by the local LLM from a consultation
/// transcript.
///
/// **Status:** minimal scaffold to unblock `SessionStore` (issue #2).
/// The authoritative prompt + parser + JSON schema are owned by:
///   - #4 `ClinicalNotesPromptBuilder` — SOAP prompt + JSON schema guard.
///   - #5 `ClinicalNotesProcessor` — transcript → `StructuredNotes`.
///
/// Fields here match the locked ReviewScreen wireframe (#13): four SOAP
/// sections, a list of selected manipulation IDs, and the "excluded"
/// content the LLM deliberately dropped from the final note (small talk,
/// unrelated tangents) so the practitioner can re-add anything worth
/// keeping. Extend here — do not rename — so #2's `ClinicalSession.draftNotes`
/// field survives #4/#5 landing without a downstream refactor.
///
/// All PHI. Never serialised to disk, never logged. See
/// `.claude/references/phi-handling.md`.
struct StructuredNotes: Sendable, Equatable {
    var subjective: String
    var objective: String
    var assessment: String
    var plan: String

    /// Manipulation IDs selected for the treatment_note (refers to the
    /// placeholder taxonomy in #6 / `ManipulationsRepository`).
    var selectedManipulationIDs: [String]

    /// Snippets the LLM excluded from the SOAP note. Displayed in the
    /// ReviewScreen excluded drawer; each entry can be re-added to a SOAP
    /// section by the practitioner.
    var excluded: [String]

    init(
        subjective: String = "",
        objective: String = "",
        assessment: String = "",
        plan: String = "",
        selectedManipulationIDs: [String] = [],
        excluded: [String] = []
    ) {
        self.subjective = subjective
        self.objective = objective
        self.assessment = assessment
        self.plan = plan
        self.selectedManipulationIDs = selectedManipulationIDs
        self.excluded = excluded
    }
}
