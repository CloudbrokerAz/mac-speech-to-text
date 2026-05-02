import Foundation
import os

/// Actor-constrained protocol for the patient picker's appointment-loading
/// dependency. See `ClinikoPatientSearching` for the rationale on
/// actor-constrained protocols.
public protocol ClinikoAppointmentLoading: Actor {
    /// Load the patient's recent (past 7 days) + today's appointments. The
    /// picker's "No appointment / general note" option is rendered by the
    /// view, not represented in the response.
    ///
    /// - Parameters:
    ///   - patientID: Cliniko patient ID, opaque string. Pass through as-is;
    ///     the underlying endpoint percent-encodes it.
    ///   - reference: The "today" anchor — defaults to `Date()`. Tests pass
    ///     a fixed date so the from / to query params are deterministic.
    /// - Throws: `ClinikoError`. Same shape as `searchPatients`.
    /// - Returns: zero or more appointments, **most-recent first**
    ///   (descending by `startsAt`). Cancelled / archived /
    ///   did-not-arrive rows are filtered out and never reach the
    ///   caller.
    func recentAndTodayAppointments(
        forPatientID patientID: String,
        reference: Date
    ) async throws -> [Appointment]
}

/// Default `ClinikoAppointmentLoading` implementation. Computes a 7-day-back
/// window in UTC against the supplied `reference` date and delegates to
/// `ClinikoClient.send(.patientAppointments(...))`.
///
/// **Window definition**: the picker shows "recent + today" — concretely,
/// `[reference − 7 days, reference + 1 day)` so today's evening
/// appointments still match. Both bounds are emitted as ISO8601 in UTC,
/// matching the encoding `ClinikoEndpoint.patientAppointments` uses.
///
/// **Wire shape** (#129): the underlying request hits Cliniko's
/// `/individual_appointments` endpoint with server-side filters
/// (`q[]=patient_id:=`, `q[]=starts_at:>=`/`<=`, `q[]=cancelled_at:!?`)
/// and server-side `sort=starts_at&order=desc`. The response decodes
/// through `ClinikoAppointmentListDTO` and maps to `[Appointment]` via
/// `ClinikoAppointmentDTO.toDomainModel(parser:)`. The service layer
/// then re-applies `!isCancelled` filtering and a defensive descending
/// re-sort so a future Cliniko regression in either filter or sort
/// semantics doesn't cascade into the picker.
///
/// PHI: as with `ClinikoPatientService`, this actor never logs query
/// arguments, never logs the response, and never persists. Logging stays
/// inside `ClinikoClient`.
public actor ClinikoAppointmentService: ClinikoAppointmentLoading {
    private let client: ClinikoClient
    private let parser: ClinikoDateParser

    /// Page size we cap the request at via `per_page` (mirrors the
    /// constant in `ClinikoEndpoint.queryItems` for the
    /// `.patientAppointments` arm). The picker doesn't paginate today;
    /// hitting this cap is a soft signal that the window is too wide
    /// for the tenant.
    private static let perPageCap = 50

    private let logger = Logger(
        subsystem: "com.speechtotext",
        category: "ClinikoAppointmentService"
    )

    public init(client: ClinikoClient) {
        self.client = client
        self.parser = ClinikoDateParser()
    }

    /// Conformance to `ClinikoAppointmentLoading`. Note: no default for
    /// `reference` here even though Swift would accept one — defaults on
    /// protocol witnesses don't surface through the existential, so
    /// providing one would silently mislead callers who think they can
    /// omit the argument when they hold an `any ClinikoAppointmentLoading`.
    public func recentAndTodayAppointments(
        forPatientID patientID: String,
        reference: Date
    ) async throws -> [Appointment] {
        // Use a UTC-pinned `Calendar` so day arithmetic is timezone-stable
        // (the underlying endpoint emits ISO8601 in UTC). Gregorian + UTC
        // sidesteps both wall-clock DST shifts and any locale-induced
        // calendar drift; falling back to seconds-arithmetic on a
        // `preconditionFailure` is purely defensive — Calendar+Gregorian
        // never returns nil for ±N day offsets from a valid `Date`.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        guard
            let from = utc.date(byAdding: .day, value: -7, to: reference),
            let to = utc.date(byAdding: .day, value: 1, to: reference)
        else {
            preconditionFailure("ClinikoAppointmentService: ±day arithmetic returned nil for a valid reference date")
        }
        let response: ClinikoAppointmentListDTO = try await client.send(
            .patientAppointments(patientID: patientID, from: from, to: to)
        )
        // Soft warn when the response was truncated — `per_page=50` is
        // the cap, and a `total_entries > 50` means the picker is
        // showing only the most-recent slice. PHI: only the integer
        // counts are logged (no patient id, no appointment ids, no
        // timestamps). A doctor with a high-volume tenant can still
        // see ALL appointments via Cliniko itself; this surfaces
        // ops-side that the cap matters for them.
        if let total = response.totalEntries,
           total > response.individualAppointments.count {
            logger.notice(
                "ClinikoAppointmentService: appointment list truncated count=\(response.individualAppointments.count, privacy: .public) total=\(total, privacy: .public) cap=\(Self.perPageCap, privacy: .public)"
            )
        }
        // Map DTO → domain. Date parsing happens here (NOT in the
        // top-level `JSONDecoder` strategy) because Cliniko emits AU
        // shard `+10:00` and `+1000` offsets that the default
        // `.iso8601` strategy mishandles — see
        // `ClinikoDateParser` for the four-pass cascade.
        //
        // Sibling structural log for `.dateMalformed` (#131): the
        // `ClinikoClient` kind-tag log at the `JSONDecoder` boundary
        // cannot fire here because the throw happens AFTER the
        // decoder already succeeded. Without this catch, a date-parse
        // failure would surface to the picker with no `OSLog`
        // breadcrumb at all. The catch is narrowed to
        // `.dateMalformed` specifically so the case name is a
        // structural-known constant (no `String(describing: error)`,
        // forbidden by `Sources/Services/Cliniko/AGENTS.md` §"PHI in
        // logs"); `batchCount` is a row count, never an identifier;
        // `pathTemplate` is `/individual_appointments?q[]={…}` —
        // structural by design. Re-throw preserves the existing
        // surface for `PatientPickerViewModel`.
        let domain: [Appointment]
        do {
            domain = try response.individualAppointments.map { dto in
                try dto.toDomainModel(parser: parser)
            }
        } catch ClinikoError.dateMalformed {
            let pathTemplate = ClinikoEndpoint
                .patientAppointments(patientID: patientID, from: from, to: to)
                .pathTemplate
            logger.error(
                "ClinikoAppointmentService: appointment date parse failed kind=dateMalformed batchCount=\(response.individualAppointments.count, privacy: .public) path=\(pathTemplate, privacy: .public)"
            )
            throw ClinikoError.dateMalformed
        }
        // Defensive client-side filter + sort. The server-side
        // `q[]=cancelled_at:!?` should already exclude cancelled rows,
        // but we re-filter on the wider `!isCancelled` derivation
        // (`cancelled_at` OR `archived_at` OR `did_not_arrive == true`)
        // because we do NOT trust either Cliniko or our own URL builder
        // to defend the picker against showing a non-attachable slot.
        // Same belt-and-braces shape as #127's archived-patient filter.
        return domain
            .filter { !$0.isCancelled }
            .sorted { $0.startsAt > $1.startsAt }
    }
}
