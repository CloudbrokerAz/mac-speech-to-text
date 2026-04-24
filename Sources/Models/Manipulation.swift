import Foundation

/// A single chiropractic manipulation technique in the app's taxonomy.
///
/// Loaded from a bundled JSON resource via `ManipulationsRepository`
/// (issue #6). v1 ships with a seven-entry placeholder list; the real
/// Cliniko manipulation-codes taxonomy will replace the JSON file once
/// the practitioner supplies it — no code changes required.
///
/// Fields:
/// - `id` — stable string identifier referenced from
///   `StructuredNotes.selectedManipulationIDs` and the Cliniko export
///   mapping (#10). Matching is by `id`, not by `displayName`.
/// - `displayName` — practitioner-facing label rendered in the
///   ReviewScreen manipulation checklist (#13).
/// - `clinikoCode` — optional code emitted into the Cliniko
///   `treatment_note` payload once the real taxonomy lands. `nil` for
///   every entry in the v1 placeholder list.
///
/// JSON shape (snake_case to match the file shipped from Cliniko):
/// ```json
/// { "id": "diversified_hvla", "display_name": "Diversified HVLA", "cliniko_code": null }
/// ```
///
/// Not PHI — this is a static taxonomy, never patient data.
struct Manipulation: Codable, Sendable, Identifiable, Equatable, Hashable {
    let id: String
    let displayName: String
    let clinikoCode: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case clinikoCode = "cliniko_code"
    }
}
