import Foundation

/// A type-tagged Cliniko identifier — patient, appointment, or note.
///
/// Cliniko's wire shape for these resources is mixed: `Patient.id` is
/// documented as `string($int64)` and decoded as `String` (#127);
/// `Appointment.id` and `TreatmentNoteCreated.id` are still numeric
/// (`Int`). The audit ledger and `SessionStore` need an opaque-but-typed
/// handle that:
///
/// 1. **Refuses free-form strings** at every migrated callsite.
///    `AuditRecord.init(patientID:)` accepts only `OpaqueClinikoID`, not
///    `String` — so a contributor cannot accidentally widen the audit
///    schema to carry a patient name without changing the type. The
///    type *itself* is total over `String` (`init(rawValue:)` is
///    public for `Codable` round-trip), but every migrated boundary
///    speaks the typed form, which is the load-bearing win.
/// 2. Encodes/decodes as a **bare** JSON string so the on-disk
///    `audit.jsonl` schema stays unchanged from the `String`-typed
///    predecessor (issue #59 acceptance: audit-row schema unchanged on
///    disk). `RawRepresentable`'s synthesised Codable would emit a
///    wrapping `{"rawValue":"..."}` object — the custom `init(from:)`
///    / `encode(to:)` below flatten to a single-value container.
///    Pinned at the byte level by
///    `AuditStoreTests.line_pins_opaque_id_byte_shape`.
/// 3. Round-trips through the `Int` ↔ `String` boundary in one place.
///    Production code uses `init(_ int: Int)` at numeric Cliniko-response
///    boundaries (`Appointment.id`, `TreatmentNoteCreated.id`) and
///    `init(_ string: String)` at the `Patient.id` boundary (#127);
///    `init(rawValue: String)` is reserved for Codable round-trip from
///    `audit.jsonl` and for tests that want deterministic string
///    literals.
///
/// **Issue #59.** Replaces the three bare-`String` ID fields on
/// `AuditRecord` and the two on `ClinicalSession`. Wire-shape IDs on
/// `Appointment` and `TreatmentNotePayload` remain `Int` — those are
/// what Cliniko's HTTP API speaks for those resources. `Patient.id`
/// flipped to `String` in #127 to match Cliniko's documented
/// `string($int64)` shape.
///
/// **`RawRepresentable` rationale.** Required by the issue spec for
/// symmetry with the predecessor `String`-typed fields and so the
/// `rawValue` accessor is callable at the few legitimate string
/// boundaries (Codable, debug formatting). Do NOT drop the conformance
/// without first removing the custom `Codable` methods below — the
/// synthesised `RawRepresentable` Codable would re-emit the wrapping-
/// object shape and silently break `audit.jsonl` back-compat.
///
/// **PHI posture.** An `OpaqueClinikoID` is the same opaque resource
/// ID the Cliniko API itself logs in its CDN/load-balancer access
/// logs — it is not a name, DOB, or contact field. But it is
/// patient-correlatable: a `patient_id` in a leaked log is enough to
/// re-identify the patient given access to the Cliniko tenant.
/// Therefore: never use `OSLog`'s `privacy: .public` on an
/// `OpaqueClinikoID`, never interpolate one into a
/// `fatalError`/`assertionFailure` message. There is deliberately
/// **no** `CustomStringConvertible` conformance — `\(id)` falls back
/// to Swift's reflection-based form (`OpaqueClinikoID(rawValue:
/// "1001")`) which is obviously-PHI-shaped, so an accidental log
/// site reads as a leak rather than as an innocuous integer.
public struct OpaqueClinikoID: RawRepresentable, Sendable, Hashable {
    public let rawValue: String

    /// Canonical construction at the numeric Cliniko-response boundary.
    /// Use this when you have a numeric `id` from an `Appointment` or
    /// `TreatmentNoteCreated` and want to type-tag it before passing
    /// into `SessionStore` or `AuditRecord`.
    public init(_ int: Int) {
        self.rawValue = String(int)
    }

    /// Canonical construction at the string-shaped Cliniko-response
    /// boundary (`Patient.id` per Cliniko's documented `string($int64)`
    /// shape — see #127). Use this when you have a `String` `id` from
    /// a `Patient` and want to type-tag it before passing into
    /// `SessionStore`. Distinct from `init(rawValue:)` so a contributor
    /// reading the call site can tell production type-tagging apart
    /// from Codable / test deterministic-literal wiring.
    public init(_ string: String) {
        self.rawValue = string
    }

    /// String-form construction. **Reserved for `Codable` round-trip**
    /// (decoding from `audit.jsonl` or test fixtures) and test wiring
    /// that wants a deterministic literal. Production callsites must
    /// use `init(_:Int)` or `init(_:String)` at the Cliniko-response
    /// boundary — `PatientPickerViewModel`, `TreatmentNoteExporter`,
    /// and the `AuditRecord` construction in the exporter all do this.
    /// A `String` value entering this initialiser at a non-Codable,
    /// non-test callsite is a #59 regression.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

extension OpaqueClinikoID: Codable {
    /// Decodes from a bare JSON string (e.g. `"1001"`). Preserves
    /// audit-jsonl back-compat — a row encoded before #59 had
    /// `"patient_id": "1001"`, so the post-#59 decoder reads that same
    /// shape rather than expecting a wrapping `{"rawValue":"1001"}`
    /// object.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(String.self)
    }

    /// Encodes as a bare JSON string. Pinned by
    /// `OpaqueClinikoIDTests.codable_encodesAsBareString` (type-level)
    /// and `AuditStoreTests.line_pins_opaque_id_byte_shape`
    /// (integration-level) so a future refactor that drops these
    /// custom methods can't accidentally re-emit `RawRepresentable`'s
    /// synthesised wrapping-object shape.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
