import Foundation

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
    /// - Returns: zero or more appointments, Cliniko's natural order.
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
/// PHI: as with `ClinikoPatientService`, this actor never logs query
/// arguments, never logs the response, and never persists. Logging stays
/// inside `ClinikoClient`.
public actor ClinikoAppointmentService: ClinikoAppointmentLoading {
    private let client: ClinikoClient

    public init(client: ClinikoClient) {
        self.client = client
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
        let response: AppointmentListResponse = try await client.send(
            .patientAppointments(patientID: patientID, from: from, to: to)
        )
        return response.appointments
    }
}
