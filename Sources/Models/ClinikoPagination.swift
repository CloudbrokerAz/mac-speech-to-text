import Foundation

/// Cliniko paginates list endpoints with a `{ <items>, total_entries, links }`
/// envelope. The picker UI for #9 only needs the first page, so the wrappers
/// surface the items directly and expose `links` / `totalEntries` for any
/// future paginate-helper. No follow-up `links.next` fetch is wired today —
/// adding one is a one-line change at the service layer.
public struct PatientSearchResponse: Decodable, Sendable, Equatable {
    public let patients: [Patient]
    public let totalEntries: Int?
    public let links: ClinikoPaginationLinks?

    public init(
        patients: [Patient],
        totalEntries: Int? = nil,
        links: ClinikoPaginationLinks? = nil
    ) {
        self.patients = patients
        self.totalEntries = totalEntries
        self.links = links
    }
}

// Note: `AppointmentListResponse` was removed in #129. The appointment
// list now decodes through `ClinikoAppointmentListDTO` (wire-shape) and
// maps to `[Appointment]` via `ClinikoAppointmentDTO.toDomainModel(parser:)`
// at the service layer. Cliniko's `/individual_appointments` envelope key
// is `individual_appointments`, not `appointments` — the previous shape
// failed to decode any populated response. See the DTO file at
// `Sources/Models/ClinikoAppointmentDTO.swift`.

/// `links` envelope shared by every Cliniko list endpoint. We don't follow
/// `next` today — keep the type loose (`URL?`) so a future paginate helper
/// can opt in without a model change. Cliniko also returns a `self` link;
/// it's intentionally not modelled here because including it would require
/// either a backtick-quoted keyword property (Swift 6 makes this a syntax
/// pain in `init`) or a renamed key strategy. Add it when we actually need
/// it.
public struct ClinikoPaginationLinks: Decodable, Sendable, Equatable {
    public let next: URL?

    public init(next: URL? = nil) {
        self.next = next
    }
}
