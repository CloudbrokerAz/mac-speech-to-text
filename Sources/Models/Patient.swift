import Foundation

/// A Cliniko patient as the picker UI needs to display them.
///
/// Wire shape: Cliniko's `GET /patients` returns snake-cased fields and
/// `date_of_birth` in `YYYY-MM-DD` (calendar date — *not* the `iso8601`
/// datetime that `ClinikoClient.defaultDecoder` is configured for). We
/// therefore decode `dateOfBirth` as a `String?` and let the view format
/// it; the alternative (a per-endpoint custom date strategy) buys nothing
/// for the picker, which only renders the field, never reasons about it.
///
/// **Field nullability** (issue #127): `id` is `String` because Cliniko's
/// OpenAPI declares the field as `string($int64)` even though almost every
/// tenant emits a numeric literal in practice; `firstName` and `lastName`
/// are `String?` because Cliniko legitimately returns `null` for
/// contact-only / incomplete-record rows. Archived rows can also have
/// stripped name fields, but those are filtered out at the service layer
/// (`ClinikoPatientService` drops rows with non-nil `archivedAt` per the
/// reference impl in `epc-letter-generation`) so they should not normally
/// reach the picker. Earlier versions of this model declared all three
/// non-optional, which surfaced as
/// `ClinikoError.decoding(typeName: "PatientSearchResponse")` whenever a
/// real tenant returned a populated response containing such a row — see
/// the regression fixtures at
/// `Tests/SpeechToTextTests/Fixtures/cliniko/responses/patients_search_partial_names.json`.
///
/// **Identity / equality** (issue #127): equality and hashing are over
/// `id` only, not the whole struct. A patient is identified by their
/// Cliniko ID; two fetches of the same patient with a populated `email`
/// or flipped `archivedAt` must still equal each other so a
/// `Set<Patient>` dedupes correctly and SwiftUI's `ForEach` diffing is
/// stable across refetches.
///
/// PHI: every field on this struct is patient data. The picker holds it in
/// memory only — no logging, no `UserDefaults`, no on-disk cache. See
/// `.claude/references/phi-handling.md`.
public struct Patient: Decodable, Identifiable, Sendable {
    /// Cliniko patient ID. Wire shape per Cliniko's OpenAPI is
    /// `string($int64)`. Stored as `String` so the decoder accepts the
    /// documented shape; the picker type-tags it into `OpaqueClinikoID`
    /// at the `SessionStore` boundary
    /// (`ClinicalSession.selectedPatientID`) via `OpaqueClinikoID(_:String)`
    /// — see #59 / #127.
    public let id: String

    /// Patient's first / given name, or `nil` if the practitioner has not
    /// recorded one. Cliniko returns `null` here for contact-only /
    /// incomplete-record patients (archived rows with stripped names are
    /// filtered upstream by `ClinikoPatientService`); the picker renders
    /// a fallback via `displayName`. See #127.
    public let firstName: String?

    /// Patient's last / family name. Same nullability rationale as
    /// `firstName`.
    public let lastName: String?

    /// Date of birth in `YYYY-MM-DD` form (Cliniko's documented shape) or
    /// `nil` if the practitioner hasn't recorded one. Kept as a `String` —
    /// see the type-level note above.
    public let dateOfBirth: String?

    /// Best-effort primary contact for the picker row. Cliniko exposes a
    /// patient's primary email at the top level (`email`); we display this
    /// rather than digging into `patient_phone_numbers` which is a separate,
    /// nested array per the API.
    public let email: String?

    /// Cliniko's archive timestamp (ISO-8601 string in the wire shape) when
    /// a patient row has been soft-deleted. `nil` for active patients.
    /// `ClinikoPatientService` filters archived rows out of search results
    /// because they typically have stripped name fields and the picker
    /// surfacing them confuses the export workflow. See #127 and the
    /// reference impl in `epc-letter-generation`.
    public let archivedAt: String?

    public init(
        id: String,
        firstName: String? = nil,
        lastName: String? = nil,
        dateOfBirth: String? = nil,
        email: String? = nil,
        archivedAt: String? = nil
    ) {
        self.id = id
        self.firstName = firstName
        self.lastName = lastName
        self.dateOfBirth = dateOfBirth
        self.email = email
        self.archivedAt = archivedAt
    }

    /// Human-readable name for the picker row + the export confirmation
    /// surface. Drops nil/empty parts and falls back to "Unnamed patient"
    /// when neither name is present (contact-only rows that aren't
    /// filtered out upstream still need a sensible UI string). Mirrors
    /// the `toDomainModel()` pattern in `epc-letter-generation`'s
    /// `ClinikoPatientService`.
    ///
    /// PHI: this is the patient's name composed from `firstName` /
    /// `lastName`. Safe inside SwiftUI body and
    /// `SessionStore.selectedPatientDisplayName` (in-memory only). Never
    /// log it, never use `OSLog privacy: .public`, never interpolate
    /// into `assertionFailure`. See `.claude/references/phi-handling.md`.
    ///
    /// Copy review (follow-up): the "Unnamed patient" fallback is a
    /// user-visible string and belongs in the same review bucket as the
    /// safety-disclaimer copy (#12). Localise via `String(localized:)`
    /// once the localisation strategy lands; tracked outside this issue.
    public var displayName: String {
        // Trim each part so whitespace-only Cliniko values (e.g. `" "`,
        // which a stripped-but-not-null field can carry) collapse to
        // empty and fall through to the "Unnamed patient" fallback.
        // Without trimming, the picker would render double spaces or
        // a leading/trailing space when one part is whitespace-only.
        let parts = [firstName, lastName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? "Unnamed patient" : parts.joined(separator: " ")
    }
}

extension Patient: Equatable, Hashable {
    /// Identity-based equality: two `Patient` values are equal iff their
    /// Cliniko `id`s match. Whole-struct equality would mark two fetches
    /// of the same patient as non-equal whenever Cliniko populated /
    /// flipped any optional field between calls — breaking
    /// `Set<Patient>` dedupe and SwiftUI's `ForEach` diff stability for
    /// no useful reason. The wire-shape fields are still inspected by
    /// the picker for rendering; equality is purely about identity.
    public static func == (lhs: Patient, rhs: Patient) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
