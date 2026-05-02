import Foundation
import os

/// Wire-shape DTO for Cliniko's `/individual_appointments` payload.
///
/// **Why a DTO + domain split** (issue #129): Cliniko's response carries
/// fields we cannot decode through the global `ClinikoClient.defaultDecoder`
/// without breaking — specifically the AU `+10:00` / `+1000` ISO8601
/// offset variants that `JSONDecoder.DateDecodingStrategy.iso8601` either
/// half-supports or rejects outright. The DTO holds dates as raw `String`
/// and the service layer parses them in `toDomainModel(parser:)` via
/// `ClinikoDateParser`, mirroring the reference Cliniko integration in
/// `CloudbrokerAz/epc-letter-generation`.
///
/// **Pre-#129 history**: an earlier `Appointment: Decodable` model
/// (numeric `id: Int`, `Date` strategy applied uniformly, top-level
/// envelope key `appointments`) failed to decode any populated response
/// because the wire shape diverged on four independent axes. The DTO
/// encapsulates the wire shape, and the domain model
/// (`Sources/Models/Appointment.swift`) carries only the parsed,
/// presentation-shaped fields the picker + export flow need.
///
/// **Decoder strategy**: this DTO relies on `JSONDecoder` with
/// `.convertFromSnakeCase` (the existing `ClinikoClient.defaultDecoder`),
/// which auto-maps `starts_at` → `startsAt`, `cancelled_at` → `cancelledAt`,
/// `appointment_type` → `appointmentType`, etc. Explicit `CodingKeys` are
/// deliberately omitted because they would *conflict* with
/// `.convertFromSnakeCase` (the strategy rewrites JSON keys before they
/// match CodingKeys, so an explicit `case startsAt = "starts_at"` would
/// look for the post-strategy key `"startsAt"` — same name, but breaks if
/// the strategy is ever changed).
///
/// **PHI**: this is a transient decode artefact. The DTO never enters
/// `OSLog`, never crosses an actor boundary except inside the service,
/// never lands on disk. After `toDomainModel` runs, the DTO is dropped.
struct ClinikoAppointmentDTO: Decodable, Sendable {
    let id: String
    let startsAt: String
    let endsAt: String?
    let cancelledAt: String?
    let archivedAt: String?
    let didNotArrive: Bool?
    let patient: LinkRef?
    let appointmentType: LinkRef?
    let practitioner: LinkRef?

    /// Cliniko's ubiquitous reference-only nested object: `{ "links": { "self": "<url>" } }`.
    /// We extract the trailing path segment as the related resource ID
    /// (e.g. `https://api.au1.cliniko.com/v1/appointment_types/4321` →
    /// `"4321"`). All fields are optional because Cliniko omits the
    /// nested object entirely on appointments without that relationship.
    struct LinkRef: Decodable, Sendable {
        let links: Links?

        struct Links: Decodable, Sendable {
            // Swift property name `self` requires backticks; JSON key is
            // `self`. `.convertFromSnakeCase` does not transform a
            // single-word lowercase key, so this matches verbatim.
            let `self`: String?
        }

        /// Trailing URL path segment of `links.self`, or `nil` if the
        /// link is missing, empty, or unparseable. Cliniko's resource
        /// URLs are canonically `<base>/<resource>/<id>`, so the last
        /// path segment is the related resource's ID. Parsed via
        /// `URL.pathComponents` so query strings (`patients/1001?include=archived`)
        /// and fragments (`patients/1001#anchor`) are stripped before
        /// the segment lookup, and trailing slashes are tolerated by
        /// the path-component splitter.
        var trailingID: String? {
            guard let raw = links?.`self`,
                  let url = URL(string: raw)
            else { return nil }
            return url.pathComponents.last(where: { $0 != "/" && !$0.isEmpty })
        }
    }

    /// Map this wire-shape DTO into the presentation-shaped domain model.
    /// Throws `ClinikoError.dateMalformed` (#131) if `startsAt` is
    /// malformed; `endsAt` failure degrades to `nil` because Cliniko has
    /// been observed emitting incomplete end times on edge appointment
    /// types and the picker can render without one. The degradation is
    /// surfaced via a structural log on `ClinikoAppointmentDTO`'s logger
    /// so a tenant-wide regression in Cliniko's `ends_at` shape is
    /// visible in `OSLog` without leaking PHI.
    ///
    /// **Future-proofing note**: `isCancelled` is derived from
    /// `cancelled_at`, `archived_at`, and `did_not_arrive`. If Cliniko
    /// ever introduces a new exclusion-shaped status field (e.g.
    /// `marked_no_show`, `voided`), update this derivation alongside
    /// the DTO's properties — silently ignoring a new field would let
    /// a non-attachable slot land in the picker.
    func toDomainModel(parser: ClinikoDateParser) throws -> Appointment {
        let startsAtDate = try parser.parse(startsAt)
        let endsAtDate: Date?
        if let endsAtString = endsAt {
            do {
                endsAtDate = try parser.parse(endsAtString)
            } catch {
                // Structural log only — no PHI (no patient/appointment
                // IDs, no value strings). Lets ops detect a tenant-wide
                // regression in Cliniko's ends_at shape without
                // breaking the picker UX (the slot still renders; the
                // most-likely-this-recording slot-containing rule
                // simply degrades to nearest-startsAt).
                Self.logger.error("ClinikoAppointmentDTO: ends_at parse failed; degrading to nil")
                endsAtDate = nil
            }
        } else {
            endsAtDate = nil
        }
        let cancelled = cancelledAt != nil
            || archivedAt != nil
            || (didNotArrive ?? false)
        return Appointment(
            id: id,
            startsAt: startsAtDate,
            endsAt: endsAtDate,
            isCancelled: cancelled,
            appointmentTypeID: appointmentType?.trailingID,
            practitionerID: practitioner?.trailingID
        )
    }

    /// File-scoped logger. Tag is a constant; never carries PHI.
    private static let logger = os.Logger(
        subsystem: "com.speechtotext",
        category: "ClinikoAppointmentDTO"
    )
}

/// Top-level envelope for `GET /individual_appointments?...`. Cliniko's
/// list endpoints share this shape (a typed `array` field, optional
/// `total_entries`, optional `links`) — only the array's field name
/// changes per resource. The patient endpoint has `patients`; this one
/// has `individual_appointments`.
struct ClinikoAppointmentListDTO: Decodable, Sendable {
    let individualAppointments: [ClinikoAppointmentDTO]
    let totalEntries: Int?
    let links: ClinikoPaginationLinks?
}
