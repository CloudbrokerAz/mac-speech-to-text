import Foundation

/// A Cliniko appointment as the picker UI needs to display them.
///
/// Wire shape: Cliniko's `GET /patients/{id}/appointments` returns numeric
/// `id` and ISO8601 `starts_at` / `ends_at` (datetime with timezone), which
/// `ClinikoClient.defaultDecoder` decodes natively via `.iso8601`.
///
/// PHI: appointment timing combined with a known patient is PHI. Held in
/// memory only — no logging beyond structural fields, no on-disk cache.
public struct Appointment: Decodable, Identifiable, Sendable, Equatable, Hashable {
    /// Cliniko numeric appointment ID. Stored as `Int` to match the wire
    /// shape; the picker type-tags it into `OpaqueClinikoID` at the
    /// `SessionStore` boundary
    /// (`ClinicalSession.selectedAppointmentID`) — see #59.
    public let id: Int

    /// Scheduled start time. Required by Cliniko's schema.
    public let startsAt: Date

    /// Scheduled end time. Optional in case Cliniko ever returns an open-
    /// ended appointment; today it's always present.
    public let endsAt: Date?

    public init(id: Int, startsAt: Date, endsAt: Date? = nil) {
        self.id = id
        self.startsAt = startsAt
        self.endsAt = endsAt
    }
}
