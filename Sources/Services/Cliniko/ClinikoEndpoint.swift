import Foundation

/// Closed-set of Cliniko endpoints in scope for v1. Each case carries the
/// minimum information the client needs to build a request and surface a
/// semantic 404 (`resource`). Adding an endpoint is a one-line enum addition
/// plus arms in the four computed properties below.
///
/// The endpoint enum stays free of response-decoding concerns: callers pass
/// `T: Decodable` to `ClinikoClient.send(_:)` and the client decodes against
/// the raw 2xx body. Pagination wrappers, request envelopes, and patient /
/// appointment / treatment_note model types live in their consuming PRs
/// (#9 / #10) — `ClinikoEndpoint` is intentionally untyped on the response
/// shape so #8 doesn't pre-empt those design decisions.
public enum ClinikoEndpoint: Sendable, Equatable {
    /// `GET /user` — used by the Cliniko settings UI's Test Connection
    /// button (originally via `ClinikoAuthProbe` in #7; the VM may switch
    /// to `client.send(.usersMe)` in a follow-up). The case name keeps the
    /// `usersMe` identifier for source-compat; only the path is `/user`,
    /// which is Cliniko's actual authenticated-user endpoint
    /// (`/users/me` does not exist — it 404s, see #88).
    case usersMe

    /// `GET /patients?q[]=field:~term` — debounced patient search for #9.
    /// Cliniko's `/patients` filter takes Ransack-style array filters;
    /// a bare `q=value` 5xx'd in production. See #101 +
    /// `patientSearchQueryItems` for the splitting strategy.
    case patientSearch(query: String)

    /// `GET /individual_appointments?q[]=patient_id:=<id>&q[]=starts_at:>=<from>&q[]=starts_at:<=<to>&q[]=cancelled_at:!?&sort=starts_at&order=desc&per_page=50`
    /// — recent + today's appointments for the chosen patient (#9).
    /// Switched from the previous `/patients/{id}/appointments` shape in
    /// #129: the per-patient shorthand returned a different envelope shape
    /// (`appointments` vs `individual_appointments`) and didn't accept the
    /// `q[]=cancelled_at:!?` filter that lets the picker drop cancelled
    /// rows server-side. The new path also takes server-side
    /// `sort=starts_at&order=desc` so the most-recent slot lands first.
    /// Defensive client-side filtering + sorting still runs in
    /// `ClinikoAppointmentService` (`!isCancelled`, descending re-sort).
    /// Mirrors the reference impl in
    /// `CloudbrokerAz/epc-letter-generation/Sources/Services/Cliniko/ClinikoAppointmentService.swift`.
    case patientAppointments(patientID: String, from: Date, to: Date)

    /// `POST /treatment_notes` with a JSON body — #10 will own the codable
    /// payload; this PR keeps the body opaque so #8 doesn't pre-empt the
    /// payload shape. **Not** auto-retried on 5xx (see `allowsRetryOn5xx`).
    case createTreatmentNote(body: Data)

    /// HTTP method strings published as a typed sub-enum so callers can't
    /// accidentally type `"get"` and skip the retry classification.
    public enum Method: String, Sendable {
        case get = "GET"
        case post = "POST"
        case patch = "PATCH"
        case delete = "DELETE"
    }

    public var method: Method {
        switch self {
        case .usersMe, .patientSearch, .patientAppointments: return .get
        case .createTreatmentNote: return .post
        }
    }

    /// Path **template** for logging. Bound IDs MUST NOT appear in logs per
    /// `.claude/references/phi-handling.md`; the client logs this string
    /// while building the resolved URL separately.
    public var pathTemplate: String {
        switch self {
        case .usersMe: return "/user"
        case .patientSearch: return "/patients?q[]={filter}"
        // Path template is PHI-safe — no bound IDs. The actual filters
        // (patient_id, starts_at window, cancelled_at) ride in the
        // query items. Logging this template at `privacy: .public` is
        // safe; logging the resolved URL is not.
        case .patientAppointments: return "/individual_appointments?q[]={patient_id}&q[]={starts_at}"
        case .createTreatmentNote: return "/treatment_notes"
        }
    }

    /// Discriminator the client passes to `ClinikoError.notFound(resource:)`
    /// when the response is 404. Always non-optional — every endpoint maps
    /// onto a single Cliniko resource type.
    public var resource: ClinikoError.Resource {
        switch self {
        case .usersMe: return .user
        case .patientSearch, .patientAppointments: return .patient
        case .createTreatmentNote: return .treatmentNote
        }
    }

    public var body: Data? {
        switch self {
        case .createTreatmentNote(let body): return body
        case .usersMe, .patientSearch, .patientAppointments: return nil
        }
    }

    public var contentType: String? {
        switch self {
        case .createTreatmentNote: return "application/json"
        case .usersMe, .patientSearch, .patientAppointments: return nil
        }
    }

    /// Whether the endpoint is safe to retry on 5xx **or** transport
    /// failures. Per `cliniko-api.md` retry policy, `treatment_notes` POST
    /// is **not** auto-retried in either case — both 5xx (server may have
    /// applied the change) and transport (we don't know if the request
    /// landed) carry duplicate-write risk, so the same `isIdempotent`
    /// flag governs both.
    /// 429 retries with `Retry-After` are governed separately and apply
    /// even when this flag is `false`.
    public var isIdempotent: Bool {
        switch self {
        case .createTreatmentNote: return false
        case .usersMe, .patientSearch, .patientAppointments: return true
        }
    }

    /// Build the resolved request URL against a `baseURL` that includes the
    /// `/v1/` prefix (i.e. `ClinikoCredentials.baseURL`). Returns `nil` only
    /// for malformed components — in practice unreachable given the
    /// closed-set inputs and the enum-constrained shard host. Callers
    /// should treat `nil` as a programmer error and propagate up; tests
    /// pin the every-shard non-nil invariant.
    public func buildURL(against baseURL: URL) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        // `pathSuffix` returns an already-percent-encoded fragment so that
        // bound IDs containing slashes / spaces don't split the path.
        // `URLComponents.percentEncodedPath` accepts encoded input verbatim;
        // using `.path` would re-encode our `%XX` escapes into `%25XX`.
        components.percentEncodedPath = components.percentEncodedPath.appending(pathSuffix)
        if let items = queryItems {
            components.queryItems = items
        }
        return components.url
    }

    /// Path segment relative to `/v1/`, percent-encoded if it embeds a
    /// dynamic id. Bound IDs are encoded here, not in `pathTemplate`
    /// (which stays log-safe).
    private var pathSuffix: String {
        switch self {
        case .usersMe:
            return "user"
        case .patientSearch:
            return "patients"
        case .patientAppointments:
            // Patient ID lives in `q[]=patient_id:=...` query value,
            // not in the path. `URLComponents` percent-encodes query
            // values for us — see `queryItems` arm.
            return "individual_appointments"
        case .createTreatmentNote:
            return "treatment_notes"
        }
    }

    private var queryItems: [URLQueryItem]? {
        switch self {
        case .usersMe, .createTreatmentNote:
            return nil
        case .patientSearch(let query):
            // Collapse `[]` to `nil` so `buildURL` doesn't emit a stray
            // trailing `?` for empty/whitespace input. The actual
            // PHI-exposure guard against an unfiltered list-all is in
            // `ClinikoPatientService.searchPatients` — this is just URL
            // hygiene.
            let items = ClinikoEndpoint.patientSearchQueryItems(query: query)
            return items.isEmpty ? nil : items
        case .patientAppointments(let patientID, let from, let to):
            // Cliniko's `/individual_appointments` filter syntax
            // (`q[]=field:operator value`) — verified against the
            // reference impl in `epc-letter-generation`. We:
            //
            // - bind the patient ID server-side so a tampered client
            //   cannot list-all (`patient_id:=` is the equality op);
            // - constrain the window via `starts_at:>=` / `starts_at:<=`
            //   in UTC (the helper at `ClinikoEndpoint.iso8601(_:)` emits
            //   `Z`-form, which Cliniko's filter parser handles);
            // - drop cancelled rows server-side via `cancelled_at:!?`
            //   (Cliniko's "is null" filter — `:!?` reads as "no value").
            //   `archived_at` and `did_not_arrive` are NOT filtered
            //   server-side (the reference impl doesn't, and we haven't
            //   verified Cliniko accepts those filter shapes); the
            //   service layer drops them client-side via
            //   `Appointment.isCancelled`;
            // - sort server-side `starts_at desc` so the picker can
            //   render in display order without an extra sort hop;
            // - cap `per_page=50` so a runaway window can't blow the
            //   response budget. The picker doesn't paginate today
            //   (UX would benefit more from a window narrowing than from
            //   a "load more" affordance).
            return [
                URLQueryItem(name: "q[]", value: "patient_id:=\(patientID)"),
                URLQueryItem(name: "q[]", value: "starts_at:>=\(ClinikoEndpoint.iso8601(from))"),
                URLQueryItem(name: "q[]", value: "starts_at:<=\(ClinikoEndpoint.iso8601(to))"),
                URLQueryItem(name: "q[]", value: "cancelled_at:!?"),
                URLQueryItem(name: "sort", value: "starts_at"),
                URLQueryItem(name: "order", value: "desc"),
                URLQueryItem(name: "per_page", value: "50")
            ]
        }
    }

    /// Build Cliniko's filter syntax for `GET /patients?q[]=field:~term`.
    ///
    /// Cliniko's `/patients` endpoint expects array-shaped `q[]` filters
    /// with the form `field:~value` (the `~` being Cliniko's contains
    /// operator). Sending a bare `q=value` triggered issue #101 — Cliniko
    /// 5xx'd on the malformed filter, which the client mapped to
    /// `.server(status:)`, surfacing as "Cliniko had a server error" in
    /// the patient picker. Verified against the working reference impl
    /// in `CloudbrokerAz/epc-letter-generation/Sources/Services/Cliniko/`.
    ///
    /// Splitting strategy (mirrors the reference exactly):
    /// - Empty / whitespace-only → no query items. **This is URL-shape
    ///   hygiene only** — it does NOT defend against a list-all of every
    ///   patient (Cliniko serves the unfiltered list in either case). The
    ///   PHI-exposure guard for that lives in
    ///   `ClinikoPatientService.searchPatients`, which short-circuits to
    ///   an empty array before issuing the request.
    /// - 1 token → `q[]=last_name:~<token>`. Single-term searches in
    ///   clinical UI are usually a surname.
    /// - ≥2 tokens → `q[]=first_name:~<head>` + `q[]=last_name:~<tail>`,
    ///   tail = remaining tokens joined by space (handles "Mary Jane Smith"
    ///   as first="Mary", last="Jane Smith").
    ///
    /// `URLQueryItem` value-half percent-encoding is handled by
    /// `URLComponents`; `:` and `~` pass through unencoded as URL-safe
    /// characters in the query component, and any user-supplied bytes
    /// (including `&`, `=`, spaces) are escaped automatically.
    private static func patientSearchQueryItems(query: String) -> [URLQueryItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        // Use `.whitespacesAndNewlines` (vs the reference impl's `.whitespaces`)
        // so a pasted multi-line clipboard like "John\nDoe" still tokenises
        // into first/last name pair rather than landing as one weird value
        // with an embedded `%0A` on the wire (Gemini Code Assist review on #112).
        let parts = trimmed
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        if parts.count >= 2 {
            let first = parts[0]
            let last = parts.dropFirst().joined(separator: " ")
            return [
                URLQueryItem(name: "q[]", value: "first_name:~\(first)"),
                URLQueryItem(name: "q[]", value: "last_name:~\(last)")
            ]
        }
        return [URLQueryItem(name: "q[]", value: "last_name:~\(trimmed)")]
    }

    /// ISO8601 with seconds + UTC. Cliniko accepts this canonical shape for
    /// query-string date filters.
    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    /// Internal-by-design but exposed for tests that pin the encoding.
    static func iso8601(_ date: Date) -> String {
        iso8601Formatter.string(from: date)
    }
}
