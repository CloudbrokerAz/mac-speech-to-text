import Foundation

/// Three-way appointment-selection state for the Cliniko export flow.
///
/// **Issue #14.** Resolves the type-design follow-up flagged on #9's
/// pre-PR review: `selectedAppointmentID: Int?` (and the post-#59
/// `OpaqueClinikoID?` that replaced it) overloaded two distinct
/// states — "the practitioner hasn't decided yet" and "the
/// practitioner explicitly chose **no appointment** (general note)".
/// The export flow needs to distinguish them so it can:
///
/// - Block the "Confirm export" button while still in `.unset` (the
///   practitioner has not made a conscious choice).
/// - Allow `.general` to flow through to a treatment-note POST whose
///   `appointment_id` is `nil` on the wire (Cliniko accepts this
///   shape per the documented endpoint contract — see
///   `TreatmentNotePayload.appointmentID: Int?`).
/// - Allow `.appointment(...)` to bind the note to a specific
///   appointment on the patient's calendar.
///
/// The `OpaqueClinikoID` (#59) carries the appointment's opaque
/// identity at the audit-ledger boundary; the export-flow VM converts
/// to `Int` for the wire payload via `Int(id.rawValue)` with
/// explicit nil-handling.
///
/// PHI: an appointment selection is patient-correlatable but
/// metadata-shaped (id only). Treat as opaque per
/// `.claude/references/phi-handling.md`.
enum AppointmentSelection: Sendable, Equatable {
    /// The practitioner has not yet chosen between "an appointment"
    /// and "no appointment". The picker UI starts here; the export
    /// flow's confirm button is gated on this state.
    case unset

    /// The practitioner has explicitly selected "no appointment /
    /// general note". Cliniko accepts a `treatment_note` POST with
    /// `appointment_id: null` for this case.
    case general

    /// The practitioner has selected a specific appointment on this
    /// patient's calendar.
    case appointment(OpaqueClinikoID)

    /// Whether the export flow can proceed past the confirmation step.
    /// `unset` blocks; `general` and `appointment` both pass.
    var isResolved: Bool {
        switch self {
        case .unset: return false
        case .general, .appointment: return true
        }
    }

    /// The wire-shape `Int?` Cliniko's `treatment_note` endpoint
    /// expects: `nil` for `.general`, the integer form of the opaque
    /// ID for `.appointment(...)`. Returns `nil` for `.unset` —
    /// callers are expected to gate on `isResolved` before reading
    /// this; an `.unset` read producing `nil` is the same shape as
    /// `.general` and would silently mis-attribute a note to "no
    /// appointment" when the practitioner has not made a choice.
    /// Callers that ship a note based on this getter without first
    /// checking `isResolved` are reintroducing the bug class that
    /// motivated this enum.
    var wireAppointmentID: Int? {
        switch self {
        case .unset, .general:
            return nil
        case .appointment(let id):
            return Int(id.rawValue)
        }
    }
}
