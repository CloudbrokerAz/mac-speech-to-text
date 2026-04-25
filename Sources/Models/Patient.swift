import Foundation

/// A Cliniko patient as the picker UI needs to display them.
///
/// Wire shape: Cliniko's `GET /patients` returns numeric `id`, snake-cased
/// fields, and `date_of_birth` in `YYYY-MM-DD` (calendar date — *not* the
/// `iso8601` datetime that `ClinikoClient.defaultDecoder` is configured for).
/// We therefore decode `dateOfBirth` as a `String?` and let the view format
/// it; the alternative (a per-endpoint custom date strategy) buys nothing
/// for the picker, which only renders the field, never reasons about it.
///
/// PHI: every field on this struct is patient data. The picker holds it in
/// memory only — no logging, no `UserDefaults`, no on-disk cache. See
/// `.claude/references/phi-handling.md`.
public struct Patient: Decodable, Identifiable, Sendable, Equatable, Hashable {
    /// Cliniko numeric patient ID. Stored as `Int` to match the wire shape;
    /// the picker converts it to `String` at the `SessionStore` boundary
    /// (`ClinicalSession.selectedPatientID` is opaque-string-typed).
    public let id: Int

    /// Patient's first / given name. Required by Cliniko's schema, so the
    /// model declares it non-optional — a missing or `null` first-name in
    /// the wire payload will surface as `ClinikoError.decoding(...)` from
    /// the client, which is the right outcome for "Cliniko returned a
    /// patient row that violates its own schema."
    public let firstName: String

    /// Patient's last / family name.
    public let lastName: String

    /// Date of birth in `YYYY-MM-DD` form (Cliniko's documented shape) or
    /// `nil` if the practitioner hasn't recorded one. Kept as a `String` —
    /// see the type-level note above.
    public let dateOfBirth: String?

    /// Best-effort primary contact for the picker row. Cliniko exposes a
    /// patient's primary email at the top level (`email`); we display this
    /// rather than digging into `patient_phone_numbers` which is a separate,
    /// nested array per the API. A future iteration can extend this to a
    /// computed `primaryContact: String?` once the wire shape is pinned by
    /// real fixtures.
    public let email: String?

    public init(
        id: Int,
        firstName: String,
        lastName: String,
        dateOfBirth: String? = nil,
        email: String? = nil
    ) {
        self.id = id
        self.firstName = firstName
        self.lastName = lastName
        self.dateOfBirth = dateOfBirth
        self.email = email
    }
}
