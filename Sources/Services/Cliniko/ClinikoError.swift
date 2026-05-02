import Foundation

/// Typed errors surfaced by `ClinikoClient`. Cases mirror the response-code
/// → semantic-error table in `.claude/references/cliniko-api.md`. The
/// payloads are deliberately structural — none of them carry PHI, so the
/// whole enum is safe to interpolate into a log line at `OSLog`'s default
/// privacy posture (which is `.private` in release builds), and the
/// `description` property is safe at `.public`.
public enum ClinikoError: Error, Sendable, Equatable, CustomStringConvertible {
    /// 401 — API key missing, revoked, or malformed.
    case unauthenticated

    /// 403 — key valid but lacks scope, or the practitioner can't see this
    /// resource. Distinguished from `.unauthenticated` so the UI can route
    /// the user differently (re-paste key vs. ask Cliniko admin for access).
    case forbidden

    /// 404 — the requested resource doesn't exist or isn't visible to this
    /// practitioner. The `Resource` discriminator is **structural**: we
    /// never embed the patient id / name / etc. — only the type of thing
    /// that was missing.
    case notFound(resource: Resource)

    /// 422 — Cliniko returned field-level validation errors. The body shape
    /// is best-effort decoded into `[field: messages]` so the UI can render
    /// them; an empty dictionary means we couldn't parse the response.
    case validation(fields: [String: [String]])

    /// 429 — rate limit hit. `retryAfter` is the parsed `Retry-After`
    /// header value when present.
    case rateLimited(retryAfter: TimeInterval?)

    /// 5xx — Cliniko returned a server error after any allowed retries
    /// have been exhausted.
    case server(status: Int)

    /// URLSession-level transport error (no HTTP response). Carries the
    /// `URLError.Code` so the UI can distinguish offline / DNS / TLS, but
    /// never the underlying URL or message.
    case transport(URLError.Code)

    /// User cancelled the request (Swift Concurrency cancellation or
    /// URLSession-level `.cancelled`). Distinguished from `.transport`
    /// so the UI doesn't mis-render a user-cancellation as a network bug.
    case cancelled

    /// 2xx response, but the body did not decode into the requested
    /// `T: Decodable`. Carries the type name for log triage; the
    /// underlying `DecodingError` stays inside the client's logger and
    /// is **not** re-thrown (it can include JSON path fragments that may
    /// be PHI-adjacent in some payloads).
    case decoding(typeName: String)

    /// An ISO8601 datetime field decoded as `String` from a Cliniko
    /// payload could not be parsed by `ClinikoDateParser` (#131, split
    /// from #129). Distinct from `.decoding(typeName:)`, which signals a
    /// `Decodable`-machinery failure (wrong envelope shape, missing
    /// required field, type mismatch). Carries no payload — the failed
    /// input is PHI-adjacent (an appointment time + a known patient
    /// context) and must not surface in `description` or `OSLog`.
    /// A surfaced `.dateMalformed` is the third bite of the same
    /// `+10:00` / `+1000` / fractional-seconds gotcha that the parser
    /// in #129 closed off; treat it as a signal to extend the
    /// four-pass cascade in `ClinikoDateParser`.
    case dateMalformed

    /// `URLSession` returned a `URLResponse` that wasn't an
    /// `HTTPURLResponse`. Defensive against custom URLProtocols (e.g.
    /// `file://`) and never expected against real Cliniko traffic.
    case nonHTTPResponse

    /// Discriminator for `.notFound`. Filled in from `ClinikoEndpoint.resource`
    /// at the call site so the UI gets a meaningful "patient not found" /
    /// "appointment not found" / etc. without us echoing identifiers. Every
    /// endpoint provides a non-optional resource — there's no `.unknown`
    /// fallback because the client never has to guess.
    public enum Resource: String, Sendable, Equatable, CustomStringConvertible {
        case user
        case patient
        case appointment
        case treatmentNote

        public var description: String { rawValue }
    }

    public var description: String {
        switch self {
        case .unauthenticated: return "Cliniko: API key was rejected (401)"
        case .forbidden: return "Cliniko: API key is valid but lacks scope (403)"
        case .notFound(let resource): return "Cliniko: \(resource.rawValue) not found (404)"
        case .validation(let fields): return "Cliniko: validation failed (\(fields.count) field(s))"
        case .rateLimited(let retryAfter):
            if let retryAfter {
                return "Cliniko: rate limited; retry after \(Int(retryAfter))s (429)"
            }
            return "Cliniko: rate limited (429)"
        case .server(let status): return "Cliniko: server error (HTTP \(status))"
        case .transport(let code): return "Cliniko: transport error (URLError code \(code.rawValue))"
        case .cancelled: return "Cliniko: request cancelled"
        case .decoding(let typeName): return "Cliniko: failed to decode \(typeName)"
        case .dateMalformed: return "Cliniko: date parse failed"
        case .nonHTTPResponse: return "Cliniko: non-HTTP response"
        }
    }
}
