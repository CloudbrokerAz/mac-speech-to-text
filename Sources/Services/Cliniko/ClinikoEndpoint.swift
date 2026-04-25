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
    /// `GET /users/me` — used by the Cliniko settings UI's Test Connection
    /// button (originally via `ClinikoAuthProbe` in #7; the VM may switch
    /// to `client.send(.usersMe)` in a follow-up).
    case usersMe

    /// `GET /patients?q={query}` — debounced patient search for #9.
    case patientSearch(query: String)

    /// `GET /patients/{id}/appointments?from={ISO8601}&to={ISO8601}` —
    /// recent + today's appointments for the chosen patient (#9).
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
        case .usersMe: return "/users/me"
        case .patientSearch: return "/patients?q={query}"
        case .patientAppointments: return "/patients/:id/appointments"
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
            return "users/me"
        case .patientSearch:
            return "patients"
        case .patientAppointments(let patientID, _, _):
            // Encode weirdness inside the bound id (spaces, slashes, etc.).
            // We start from `urlPathAllowed` and *remove* "/" so an embedded
            // slash in the id can't accidentally introduce a new path
            // segment. Cliniko ids are numeric in practice; this is
            // defence-in-depth.
            let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
            let encoded = patientID.addingPercentEncoding(withAllowedCharacters: allowed) ?? patientID
            return "patients/\(encoded)/appointments"
        case .createTreatmentNote:
            return "treatment_notes"
        }
    }

    private var queryItems: [URLQueryItem]? {
        switch self {
        case .usersMe, .createTreatmentNote:
            return nil
        case .patientSearch(let query):
            return [URLQueryItem(name: "q", value: query)]
        case .patientAppointments(_, let from, let to):
            return [
                URLQueryItem(name: "from", value: ClinikoEndpoint.iso8601(from)),
                URLQueryItem(name: "to", value: ClinikoEndpoint.iso8601(to))
            ]
        }
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
