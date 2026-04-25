import Foundation

/// Cliniko API credentials in memory: an opaque API key plus the regional
/// shard. Conforms to `Sendable` so it can cross the actor boundary into the
/// HTTP client; conforms to `Equatable` for tests but the comparison is on
/// the *whole struct*, never on the raw key alone (no equality side channel
/// exposed).
///
/// PHI: The `apiKey` is a secret. It is **not** publicly readable — the only
/// supported accessor is `basicAuthHeaderValue`, which already encodes the
/// secret for HTTP Basic auth. `description` is overridden to redact it.
/// `Equatable` and `init(apiKey:shard:)` are the only places that touch the
/// raw key value, and `init` rejects whitespace-only / empty input so that
/// "valid credentials exist" is guaranteed by the type, not by every caller.
public struct ClinikoCredentials: Sendable, Equatable, CustomStringConvertible {
    public enum CredentialsError: Error, Sendable, Equatable, CustomStringConvertible {
        case emptyAPIKey

        public var description: String {
            switch self {
            case .emptyAPIKey: return "ClinikoCredentials: API key is empty"
            }
        }
    }

    /// The raw API key. `internal` so this file's tests can verify trim
    /// behaviour, but **not** publicly readable — `basicAuthHeaderValue` is
    /// the only sanctioned accessor for outside callers. Keeping it
    /// `internal let` prevents accidental log interpolation
    /// (`"\(creds.apiKey)"`) without burning a `private` scope that this
    /// file's tests would have to fight.
    let apiKey: String
    public let shard: ClinikoShard

    /// Failable initializer that enforces the "non-empty key" invariant at
    /// the type boundary. Trims whitespace before storing. Empty / whitespace-
    /// only keys throw `.emptyAPIKey`. Callers that already validated input
    /// can wrap with `try!` only in tests, never in production.
    public init(apiKey: String, shard: ClinikoShard) throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CredentialsError.emptyAPIKey }
        self.apiKey = trimmed
        self.shard = shard
    }

    /// Base URL for `ClinikoClient` requests. Built from `URLComponents` with
    /// enum-constrained host segments so the construction cannot fail at
    /// runtime; the `preconditionFailure` guard is defence-in-depth that
    /// would only fire if a future refactor broke the host-name invariant —
    /// a programmer bug, not a user error. `ClinikoCredentialsTests`
    /// iterates every shard to keep that invariant under test.
    public var baseURL: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = shard.apiHost
        components.path = "/v1/"
        guard let url = components.url else {
            preconditionFailure("ClinikoCredentials: enum-constrained shard host produced nil URL")
        }
        return url
    }

    /// Value for the HTTP `Authorization` header. Cliniko's auth scheme is
    /// HTTP Basic with the API key as the username and an empty password.
    /// See: https://docs.api.cliniko.com/#authentication
    public var basicAuthHeaderValue: String {
        let token = "\(apiKey):"
        let data = Data(token.utf8)
        return "Basic \(data.base64EncodedString())"
    }

    /// Custom description that never echoes the API key — protects logs and
    /// any accidental string interpolation.
    public var description: String {
        "ClinikoCredentials(shard: \(shard.rawValue), apiKey: <redacted>)"
    }
}
