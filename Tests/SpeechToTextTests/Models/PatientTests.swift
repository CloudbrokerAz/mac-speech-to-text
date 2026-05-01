import Foundation
import Testing
@testable import SpeechToText

/// Type-level tests for `Patient` — primarily the `displayName` helper
/// and Codable round-trips covering Cliniko's documented nullability
/// (#127). Service-level decode coverage lives in
/// `ClinikoPatientServiceTests`; this suite stays focused on the
/// model contract.
@Suite("Patient", .tags(.fast))
struct PatientTests {

    // MARK: - displayName fallbacks

    @Test("both names present joins with a single space")
    func displayName_bothPresent() {
        let patient = Patient(id: "1", firstName: "Sample", lastName: "Patient")
        #expect(patient.displayName == "Sample Patient")
    }

    @Test("first-name only renders without a trailing space")
    func displayName_firstNameOnly() {
        let patient = Patient(id: "1", firstName: "Sample", lastName: nil)
        #expect(patient.displayName == "Sample")
    }

    @Test("last-name only renders without a leading space")
    func displayName_lastNameOnly() {
        let patient = Patient(id: "1", firstName: nil, lastName: "Patient")
        #expect(patient.displayName == "Patient")
    }

    @Test("both names nil falls back to 'Unnamed patient'")
    func displayName_bothNil_fallback() {
        let patient = Patient(id: "1", firstName: nil, lastName: nil)
        #expect(patient.displayName == "Unnamed patient")
    }

    @Test("empty-string name fields fall back like nil")
    func displayName_emptyStrings_fallback() {
        // Cliniko sometimes returns `""` rather than `null` for
        // stripped names; the helper drops both via `.filter { !$0.isEmpty }`.
        let patient = Patient(id: "1", firstName: "", lastName: "")
        #expect(patient.displayName == "Unnamed patient")
    }

    @Test("whitespace-only name fields fall back like nil")
    func displayName_whitespaceOnly_fallback() {
        // Cliniko can carry stripped-but-not-null fields as a single
        // space or other whitespace. Without trimming, the picker
        // would render `" "` or double-spaces depending on which side
        // was stripped — both visually broken. The helper trims each
        // part so whitespace-only collapses to empty and falls
        // through to the fallback.
        let bothWhitespace = Patient(id: "1", firstName: "   ", lastName: "\t\n")
        #expect(bothWhitespace.displayName == "Unnamed patient")

        let oneWhitespace = Patient(id: "2", firstName: " ", lastName: "Patient")
        #expect(oneWhitespace.displayName == "Patient")
    }

    @Test("renders no leading/trailing space when one part is empty")
    func displayName_noBoundarySpaces() {
        // Belt-and-braces: ensure no callsite ever sees a leading or
        // trailing space character even on the corner cases.
        let firstOnly = Patient(id: "1", firstName: "Sample", lastName: nil)
        #expect(!firstOnly.displayName.hasPrefix(" "))
        #expect(!firstOnly.displayName.hasSuffix(" "))

        let lastOnly = Patient(id: "1", firstName: nil, lastName: "Patient")
        #expect(!lastOnly.displayName.hasPrefix(" "))
        #expect(!lastOnly.displayName.hasSuffix(" "))
    }

    @Test("empty first plus real last renders just the real one")
    func displayName_emptyFirst_realLast() {
        let patient = Patient(id: "1", firstName: "", lastName: "Patient")
        #expect(patient.displayName == "Patient")
    }

    // MARK: - Decode (Cliniko wire shape)

    /// String-typed `id` per Cliniko's documented `string($int64)` shape
    /// (#127). The previous `Int`-typed model failed `typeMismatch` on
    /// any populated response.
    @Test("decodes string id from wire shape")
    func decode_stringID() throws {
        let json = Data(#"""
        {
          "id": "1001",
          "first_name": "Sample",
          "last_name": "Patient",
          "date_of_birth": "1980-01-15",
          "email": "sample.patient@example.test"
        }
        """#.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let patient = try decoder.decode(Patient.self, from: json)
        #expect(patient.id == "1001")
        #expect(patient.firstName == "Sample")
        #expect(patient.lastName == "Patient")
    }

    @Test("decodes nullable name fields without throwing")
    func decode_nullNames() throws {
        let json = Data(#"""
        {
          "id": "2003",
          "first_name": null,
          "last_name": null,
          "date_of_birth": null,
          "email": null
        }
        """#.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let patient = try decoder.decode(Patient.self, from: json)
        #expect(patient.firstName == nil)
        #expect(patient.lastName == nil)
        #expect(patient.displayName == "Unnamed patient")
    }

    @Test("missing optional fields default to nil")
    func decode_missingOptionalFields() throws {
        // Real-world Cliniko payloads sometimes omit nullable fields
        // entirely rather than emitting `null`. Both shapes must decode.
        let json = Data(#"""
        {
          "id": "3001",
          "first_name": "Only",
          "last_name": "Name"
        }
        """#.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let patient = try decoder.decode(Patient.self, from: json)
        #expect(patient.dateOfBirth == nil)
        #expect(patient.email == nil)
        #expect(patient.archivedAt == nil)
    }

    // MARK: - Identity-based equality (#127)

    /// Two fetches of the same patient with different optional field
    /// values must still equal so a `Set<Patient>` dedupes and SwiftUI's
    /// `ForEach` diffing is stable across refetches.
    @Test("equality is identity-based (same id, different fields → equal)")
    func equality_identityBased() {
        let original = Patient(
            id: "1001",
            firstName: "Sample",
            lastName: "Patient",
            email: nil
        )
        let withEmail = Patient(
            id: "1001",
            firstName: "Sample",
            lastName: "Patient",
            email: "sample.patient@example.test"
        )
        let archived = Patient(
            id: "1001",
            firstName: "Sample",
            lastName: "Patient",
            archivedAt: "2026-01-01T00:00:00Z"
        )
        #expect(original == withEmail)
        #expect(original == archived)

        var bag: Set<Patient> = []
        bag.insert(original)
        bag.insert(withEmail)
        bag.insert(archived)
        #expect(bag.count == 1)
    }

    /// Different `id`s with otherwise-identical fields are not equal.
    @Test("different ids are not equal even with matching fields")
    func equality_differentIDs_notEqual() {
        let a = Patient(id: "1001", firstName: "Sample", lastName: "Patient")
        let b = Patient(id: "1002", firstName: "Sample", lastName: "Patient")
        #expect(a != b)
        #expect(a.hashValue != b.hashValue)
    }

    @Test("decodes archived_at when present")
    func decode_archivedAt() throws {
        let json = Data(#"""
        {
          "id": "4001",
          "first_name": "Archived",
          "last_name": "Row",
          "archived_at": "2020-01-01T00:00:00Z"
        }
        """#.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let patient = try decoder.decode(Patient.self, from: json)
        #expect(patient.archivedAt == "2020-01-01T00:00:00Z")
    }
}
