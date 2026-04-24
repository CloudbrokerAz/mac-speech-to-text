import Foundation
import Testing
@testable import SpeechToText

// Covers issue #6 acceptance criteria:
//   - Repo loads bundled JSON at startup and exposes [Manipulation] to
//     downstream call sites (#4 prompt builder, #13 ReviewScreen, #10
//     Cliniko export).
//   - One-file swap: populating `cliniko_code` in the source JSON flows
//     through to the repository without any code change.
//   - Malformed / missing resource paths surface typed errors so a bad
//     swap is loud, not silent.
//
// Style: Swift Testing only; `.fast` via the suite. See
// `.claude/references/testing-conventions.md`.

@Suite("ManipulationsRepository", .tags(.fast))
struct ManipulationsRepositoryTests {

    // MARK: - Bundled placeholder (production path)

    @Test("Bundled placeholder decodes to the v1 seven-entry taxonomy in declared order")
    func bundledPlaceholder_decodesToSevenKnownEntries() throws {
        let repo = try ManipulationsRepository.loadFromBundle()

        let expectedIDs = [
            "diversified_hvla",
            "gonstead",
            "activator",
            "thompson_drop",
            "sacro_occipital_technique",
            "toggle_recoil",
            "mobilisation_non_hvla"
        ]
        #expect(repo.all.map(\.id) == expectedIDs)
        #expect(repo.all.count == 7)
    }

    @Test("Every placeholder entry has a non-empty display name and nil cliniko_code")
    func bundledPlaceholder_displayNameAndClinikoCodeInvariants() throws {
        let repo = try ManipulationsRepository.loadFromBundle()

        for manipulation in repo.all {
            #expect(
                !manipulation.displayName.isEmpty,
                "display_name must be populated for \(manipulation.id)"
            )
            #expect(
                manipulation.clinikoCode == nil,
                "v1 placeholder must leave cliniko_code nil for \(manipulation.id)"
            )
        }
    }

    @Test("Bundled placeholder IDs are unique")
    func bundledPlaceholder_idsAreUnique() throws {
        // `id` is the join key for `StructuredNotes.selectedManipulationIDs`
        // and the future Cliniko export mapping (#10). A duplicate would
        // silently corrupt selection state, so the taxonomy file must keep
        // unique ids even as it grows.
        let repo = try ManipulationsRepository.loadFromBundle()
        #expect(Set(repo.all.map(\.id)).count == repo.all.count)
    }

    @Test("Empty JSON array decodes to an empty repository")
    func emptyArray_decodesToEmptyRepository() throws {
        // Pins current behaviour: an empty taxonomy file is not an error at
        // this layer. Call sites are free to add their own guard if they
        // require a non-empty list.
        let repo = try ManipulationsRepository(data: Data("[]".utf8))
        #expect(repo.all.isEmpty)
    }

    @Test("Duplicate id in JSON throws duplicateIDs with the offending ids")
    func duplicateIDs_throwTyped() {
        // A broken taxonomy swap must surface loudly — dup ids would
        // silently corrupt StructuredNotes.selectedManipulationIDs
        // matching and the #10 Cliniko export mapping.
        let dupJSON = Data("""
        [
          { "id": "activator", "display_name": "Activator",       "cliniko_code": null },
          { "id": "activator", "display_name": "Activator (copy)", "cliniko_code": null },
          { "id": "gonstead",  "display_name": "Gonstead",        "cliniko_code": null },
          { "id": "gonstead",  "display_name": "Gonstead (copy)",  "cliniko_code": null }
        ]
        """.utf8)

        #expect {
            _ = try ManipulationsRepository(data: dupJSON)
        } throws: { error in
            guard case let .duplicateIDs(ids) = error as? ManipulationsRepositoryError else {
                return false
            }
            return ids == ["activator", "gonstead"]
        }
    }

    // MARK: - One-file-swap contract (future real taxonomy)

    @Test("Populated cliniko_code round-trips through the repository")
    func realTaxonomyShape_preservesClinikoCode() throws {
        // Shape mirrors the real Cliniko taxonomy that will one day replace
        // `placeholder.json`. The values here are illustrative only.
        let realTaxonomyJSON = Data("""
        [
          { "id": "diversified_hvla", "display_name": "Diversified HVLA", "cliniko_code": "CH-DHVLA-001" },
          { "id": "activator",        "display_name": "Activator",        "cliniko_code": "CH-ACT-014" }
        ]
        """.utf8)

        let repo = try ManipulationsRepository(data: realTaxonomyJSON)

        #expect(repo.all.count == 2)
        #expect(repo.all[0].clinikoCode == "CH-DHVLA-001")
        #expect(repo.all[1].clinikoCode == "CH-ACT-014")
    }

    // MARK: - Negative paths

    @Test("Malformed JSON throws a DecodingError")
    func malformedJSON_throwsDecodingError() {
        let garbage = Data("not json".utf8)
        #expect(throws: DecodingError.self) {
            _ = try ManipulationsRepository(data: garbage)
        }
    }

    @Test("Missing required key surfaces a decoding failure")
    func missingRequiredKey_throws() {
        let invalid = Data("""
        [ { "id": "x", "cliniko_code": null } ]
        """.utf8)
        #expect(throws: (any Error).self) {
            _ = try ManipulationsRepository(data: invalid)
        }
    }

    @Test("Missing resource surfaces the typed resourceNotFound error")
    func missingResource_throwsTypedError() {
        #expect(throws: ManipulationsRepositoryError.self) {
            _ = try ManipulationsRepository.loadFromBundle(
                resource: "does-not-exist",
                subdirectory: "Manipulations"
            )
        }
    }
}
