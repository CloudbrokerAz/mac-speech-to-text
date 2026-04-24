import Foundation

/// Byte-for-byte mirror of the JSON the local LLM returns for a clinical
/// note, per the contract locked in EPIC #1.
///
/// **Not the UI model.** `ReviewScreen` (#13) binds to `StructuredNotes`,
/// which uses `selectedManipulationIDs: [String]` — stable ids from
/// `ManipulationsRepository`. The `RawLLMDraft → StructuredNotes`
/// mapping resolves the LLM's free-text `manipulations[].name` back to
/// an `id` via the taxonomy; that mapping lives in
/// `ClinicalNotesProcessor` (#5), not here.
///
/// **All PHI.** SOAP strings, excluded snippets, and manipulation names
/// can all contain transcript content. Never log, persist, or serialise
/// instances of this type outside the live session. See
/// `.claude/references/phi-handling.md`.
struct RawLLMDraft: Codable, Sendable, Equatable {
    let subjective: String
    let objective: String
    let assessment: String
    let plan: String
    let manipulations: [SuggestedManipulation]
    let excludedContent: [String]

    /// A single manipulation the LLM believes was performed, matched
    /// back to the taxonomy by `name` in `ClinicalNotesProcessor` (#5).
    struct SuggestedManipulation: Codable, Sendable, Equatable {
        let name: String
        /// Model-reported confidence. Contract: `[0.0, 1.0]`.
        /// `ClinicalNotesPromptBuilder.validate(json:)` rejects values
        /// outside that range.
        let confidence: Double
    }

    private enum CodingKeys: String, CodingKey {
        case subjective, objective, assessment, plan, manipulations
        case excludedContent = "excluded_content"
    }
}
