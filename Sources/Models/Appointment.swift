import Foundation

/// A Cliniko appointment as the picker UI needs to display them.
///
/// **Domain model — not the wire DTO.** The wire DTO lives in
/// `ClinikoAppointmentDTO` and is mapped here via `toDomainModel(parser:)`
/// at the service layer (#129). This split mirrors the patient pattern
/// from #127 and the reference Cliniko integration in
/// `CloudbrokerAz/epc-letter-generation`.
///
/// **Field nullability + types** (issue #129):
/// - `id` is `String` because Cliniko's OpenAPI declares the field as
///   `string($int64)` — same shape as `Patient.id`.
/// - `startsAt` is `Date`; `endsAt` is `Date?`. Cliniko emits ISO8601 in
///   either UTC `Z` or AU shard `+10:00` / `+1000` (no colon) form. Swift's
///   `JSONDecoder` `.iso8601` strategy famously rejects `+1000`. We therefore
///   decode dates as raw `String` in the DTO and parse them in
///   `toDomainModel` via `ClinikoDateParser` — see `Sources/Services/Cliniko/AGENTS.md`
///   §"Cliniko date offsets" for the gotcha.
/// - `isCancelled` is **derived** from the wire fields `cancelled_at`,
///   `archived_at`, and `did_not_arrive`. Any one being truthy makes the
///   appointment ineligible for note attachment; `ClinikoAppointmentService`
///   filters the list defensively after the upstream `q[]=cancelled_at:!?`
///   server filter.
///
/// **Identity / equality** (matches #127's Patient pattern): equality and
/// hashing are over `id` only. Two fetches of the same appointment with a
/// flipped `cancelled_at` must still equal each other so a `Set<Appointment>`
/// dedupes correctly and SwiftUI's `ForEach` diffing is stable across
/// refetches.
///
/// PHI: appointment timing combined with a known patient is PHI. Held in
/// memory only — no logging beyond structural fields, no on-disk cache.
public struct Appointment: Identifiable, Sendable {
    /// Cliniko appointment ID. Wire shape per Cliniko's OpenAPI is
    /// `string($int64)`. Stored as `String` so the decoder accepts the
    /// documented shape; the picker type-tags it into `OpaqueClinikoID`
    /// at the `SessionStore` boundary
    /// (`ClinicalSession.selectedAppointmentID`) via `OpaqueClinikoID(_:String)`
    /// — see #59 / #129.
    public let id: String

    /// Scheduled start time, parsed from Cliniko's wire `starts_at`.
    public let startsAt: Date

    /// Scheduled end time. Optional — Cliniko has been observed returning
    /// open-ended appointments on rare appointment-type configurations.
    public let endsAt: Date?

    /// `true` if the appointment is cancelled, archived, or marked as a
    /// did-not-arrive. The picker filters these out — they aren't valid
    /// candidates for clinical-note attachment. Derived in
    /// `ClinikoAppointmentDTO.toDomainModel(parser:)`.
    public let isCancelled: Bool

    /// Cliniko appointment-type ID, extracted from the nested
    /// `appointment_type.links.self` URL (`.../appointment_types/<id>`).
    /// `nil` if Cliniko omitted the relationship link or the URL had no
    /// trailing path component. Held for future picker / export display;
    /// not load-bearing for #129 itself.
    public let appointmentTypeID: String?

    /// Cliniko practitioner ID, extracted from the nested
    /// `practitioner.links.self` URL. Same rationale as
    /// `appointmentTypeID`.
    public let practitionerID: String?

    public init(
        id: String,
        startsAt: Date,
        endsAt: Date? = nil,
        isCancelled: Bool = false,
        appointmentTypeID: String? = nil,
        practitionerID: String? = nil
    ) {
        self.id = id
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.isCancelled = isCancelled
        self.appointmentTypeID = appointmentTypeID
        self.practitionerID = practitionerID
    }

    /// Pick the appointment most likely to be the one the doctor is
    /// recording for. Heuristic (#129):
    ///
    /// 1. **Slot-containing wins outright.** If `recordingStart` falls in
    ///    `[startsAt, endsAt)` for some appointment, return it. The doctor
    ///    pressed record during that slot — there is no ambiguity.
    /// 2. **Otherwise nearest by `startsAt`** within `maxDistance`.
    ///    Return the appointment whose `startsAt` is closest to
    ///    `recordingStart` in either direction, provided that distance
    ///    is within `maxDistance` (default: 24 hours). Beyond that we
    ///    bail to `nil` — pre-selecting an appointment that's days
    ///    away is wrong more often than right and erodes the doctor's
    ///    trust in the picker. Tied distances resolve to the appointment
    ///    in the past (`startsAt < recordingStart`) over one in the
    ///    future, since clinically a doctor records during or after
    ///    the slot, not before.
    /// 3. Returns `nil` for an empty input.
    ///
    /// This is non-blocking — the picker still lets the user pick a
    /// different appointment. The point is to skip the tap when the
    /// natural answer is unambiguous.
    public static func mostLikelyMatch(
        in appointments: [Appointment],
        for recordingStart: Date,
        maxDistance: TimeInterval = 24 * 60 * 60
    ) -> Appointment? {
        if let containing = appointments.first(where: { appointment in
            guard let endsAt = appointment.endsAt else { return false }
            return appointment.startsAt <= recordingStart && recordingStart < endsAt
        }) {
            return containing
        }
        // Explicit tie-breaker rather than inheriting the caller's input
        // ordering — keeps the helper's behaviour stable regardless of
        // how the service layer happens to sort.
        let nearest = appointments.min(by: { lhs, rhs in
            let lDistance = abs(lhs.startsAt.timeIntervalSince(recordingStart))
            let rDistance = abs(rhs.startsAt.timeIntervalSince(recordingStart))
            if lDistance != rDistance { return lDistance < rDistance }
            // Tie: prefer the past-leaning slot (startsAt < recordingStart).
            return lhs.startsAt > rhs.startsAt
                ? false
                : lhs.startsAt < recordingStart && recordingStart <= rhs.startsAt
        })
        guard let candidate = nearest,
              abs(candidate.startsAt.timeIntervalSince(recordingStart)) <= maxDistance
        else { return nil }
        return candidate
    }
}

extension Appointment: Equatable, Hashable {
    /// Identity-based equality: two `Appointment` values are equal iff
    /// their Cliniko `id`s match. Whole-struct equality would mark two
    /// fetches of the same appointment as non-equal whenever Cliniko
    /// flipped `cancelled_at` / `archived_at` between calls — breaking
    /// `Set<Appointment>` dedupe and SwiftUI's `ForEach` diff stability.
    /// Same shape as `Patient`'s post-#127 equality.
    public static func == (lhs: Appointment, rhs: Appointment) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
