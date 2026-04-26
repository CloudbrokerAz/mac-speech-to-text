import Foundation

/// Read-only snapshot of the chiropractic manipulations taxonomy loaded
/// from a bundled JSON resource.
///
/// **Issue #6.** v1 ships with a seven-entry placeholder list at
/// `Resources/Manipulations/placeholder.json`. The real Cliniko taxonomy
/// replaces that file — the repository itself never changes, so the swap
/// is one file and zero code changes (EPIC acceptance criterion).
///
/// **Call sites:**
/// - `ClinicalNotesPromptBuilder` (#4) enumerates `.all` into the LLM
///   prompt so the model knows which manipulation IDs it may select.
/// - `ReviewScreen` (#13) renders `.all` as the practitioner checklist.
/// - The Cliniko export mapping (#10) reads `clinikoCode` for each
///   selected ID.
///
/// **Thread safety.** Immutable value type; `Sendable` by construction.
///
/// **Not PHI.** Static taxonomy; nothing patient-specific reaches this
/// type.
struct ManipulationsRepository: Sendable, Equatable {
    /// Every manipulation in the taxonomy, in the order declared by the
    /// source JSON. Stable order is a UI contract — the ReviewScreen
    /// checklist renders entries in this order.
    let all: [Manipulation]

    // MARK: - Initialisation

    /// Seam used by tests and by callers assembling a repository from an
    /// already-decoded list. Duplicate IDs are a programmer error — the
    /// production `init(data:decoder:)` path enforces uniqueness at
    /// runtime; this debug-only assertion flags fixtures that mis-declare.
    init(all: [Manipulation]) {
        assert(
            Set(all.map(\.id)).count == all.count,
            "ManipulationsRepository: manipulation IDs must be unique"
        )
        self.all = all
    }

    /// Decode a taxonomy from raw JSON bytes.
    ///
    /// - Throws: `DecodingError` if `data` cannot be parsed as the
    ///   expected `[Manipulation]` shape, or
    ///   `ManipulationsRepositoryError.duplicateIDs(_:)` if the parsed
    ///   list contains duplicate `id` values. Uniqueness matters because
    ///   `id` is the join key for `StructuredNotes.selectedManipulationIDs`
    ///   and the Cliniko export mapping (#10); a dup would silently
    ///   corrupt selection state.
    init(data: Data, decoder: JSONDecoder = JSONDecoder()) throws {
        let decoded = try decoder.decode([Manipulation].self, from: data)
        let duplicates = Dictionary(grouping: decoded, by: \.id)
            .filter { $0.value.count > 1 }
            .keys
            .sorted()
        guard duplicates.isEmpty else {
            throw ManipulationsRepositoryError.duplicateIDs(duplicates)
        }
        self.all = decoded
    }

    // MARK: - Bundle loader

    /// Load the bundled taxonomy JSON.
    ///
    /// Defaults resolve to `Bundle.module` of the `SpeechToText` target
    /// and `Resources/Manipulations/placeholder.json`. Production callers
    /// should use the defaults; tests may pass a custom `bundle` to
    /// point at test fixtures.
    ///
    /// - Throws: `ManipulationsRepositoryError.resourceNotFound` if the
    ///   named file is missing from the bundle, or a `DecodingError` if
    ///   the file is present but malformed.
    static func loadFromBundle(
        _ bundle: Bundle = .module,
        resource: String = "placeholder",
        subdirectory: String = "Manipulations"
    ) throws -> ManipulationsRepository {
        guard let url = bundle.url(
            forResource: resource,
            withExtension: "json",
            subdirectory: subdirectory
        ) else {
            throw ManipulationsRepositoryError.resourceNotFound(
                resource: resource,
                subdirectory: subdirectory
            )
        }
        let data = try Data(contentsOf: url)
        return try ManipulationsRepository(data: data)
    }
}

/// Failures surfaced by `ManipulationsRepository` initialisers.
enum ManipulationsRepositoryError: Error, Equatable {
    /// The named resource is missing from the bundle. Usually a
    /// build-system misconfiguration (e.g. a missing `.copy(...)` entry
    /// in `Package.swift`).
    case resourceNotFound(resource: String, subdirectory: String)

    /// The parsed taxonomy contains duplicate `id` values. Associated
    /// value lists the offending IDs (sorted, deduplicated) so callers
    /// and test assertions have a concrete diagnostic without logging
    /// anything PHI-adjacent — the taxonomy itself is static, not
    /// patient data.
    case duplicateIDs([String])
}
