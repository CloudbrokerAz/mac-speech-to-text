import Foundation
import os.log

/// Thin Cliniko HTTP client. The single public method `send(_:)` builds an
/// authenticated request from a `ClinikoEndpoint`, retries on 429 +
/// (idempotent verbs only) 5xx / transport failures per the policy in
/// `.claude/references/cliniko-api.md`, and surfaces a typed `ClinikoError`.
/// `Decodable` responses are decoded with `convertFromSnakeCase` + ISO8601
/// dates — Cliniko's documented shape.
///
/// PHI:
/// - The API key is held only via `ClinikoCredentials` (which exposes the
///   secret only through `basicAuthHeaderValue`); the credentials struct
///   itself is `Sendable` and crosses the actor boundary fine.
/// - Logs at any privacy posture carry only structural values: HTTP method,
///   path **template** (`/patients/:id/appointments`, never the bound URL),
///   status code, latency, error case name, decoding-target type name, and
///   the URLError raw integer code. The request URL with bound IDs, the
///   request body, the response body, and the underlying `Error` value
///   (anything from another framework that might embed PHI) are **never**
///   logged.
public actor ClinikoClient {
    /// Default `User-Agent`. Mirrors `ClinikoAuthProbe.defaultUserAgent`
    /// — Cliniko requires the header to be non-empty and include a contact
    /// reference. We use the public repo URL so Cliniko ops can reach the
    /// project for abuse / incident.
    public static var defaultUserAgent: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        return "mac-speech-to-text/\(version) (https://github.com/CloudbrokerAz/mac-speech-to-text)"
    }

    /// Default JSON decoder: snake_case → camelCase + ISO8601 dates. Suitable
    /// for the documented Cliniko response shapes; consumers can supply a
    /// custom decoder for endpoints that need different strategies.
    public static var defaultDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Tunable retry behaviour. The default schedules `[1s, 2s]` between
    /// attempts and uses `Task.sleep`; tests inject `.immediate` to avoid
    /// real waits. The sleep closure is `@Sendable async throws` so
    /// cancellation propagates and tests can replace the implementation.
    public struct RetryPolicy: Sendable {
        public let delays: [TimeInterval]
        public let sleep: @Sendable (TimeInterval) async throws -> Void

        public init(
            delays: [TimeInterval],
            sleep: @escaping @Sendable (TimeInterval) async throws -> Void
        ) {
            self.delays = delays
            self.sleep = sleep
        }

        public static let `default` = RetryPolicy(
            delays: [1.0, 2.0],
            sleep: { interval in
                // `Task.sleep(for:)` is the modern replacement for the
                // nanosecond-based variant; available on macOS 13+ which
                // is below our `macOS 14` deployment target.
                try await Task.sleep(for: .seconds(max(0, interval)))
            }
        )

        /// No-wait variant for tests. Keeps the retry *count* identical to
        /// `.default` so retry-budget assertions match production shape.
        public static let immediate = RetryPolicy(
            delays: [0.0, 0.0],
            sleep: { _ in /* no-op */ }
        )

        /// Maximum number of retry attempts (after the initial request).
        var maxRetries: Int { delays.count }
    }

    // MARK: - State

    private let credentials: ClinikoCredentials
    private let session: URLSession
    private let userAgent: String
    private let retryPolicy: RetryPolicy
    private let decoder: JSONDecoder
    private let logger = Logger(subsystem: "com.speechtotext", category: "ClinikoClient")

    /// RFC 7231 IMF-fixdate parser. Used for `Retry-After: <http-date>`.
    /// Held as an *instance* property (not `static`) because `DateFormatter`
    /// is documented as thread-unsafe under mutation; even though we never
    /// mutate this one after construction, sharing a single static across
    /// multiple `ClinikoClient` actor instances would still trip Swift 6
    /// strict-concurrency checking (`DateFormatter` is not `Sendable`).
    /// Actor isolation makes the per-instance copy provably safe.
    private let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    // MARK: - Init

    public init(
        credentials: ClinikoCredentials,
        session: URLSession = .shared,
        userAgent: String = ClinikoClient.defaultUserAgent,
        retryPolicy: RetryPolicy = .default,
        decoder: JSONDecoder = ClinikoClient.defaultDecoder
    ) {
        self.credentials = credentials
        self.session = session
        self.userAgent = userAgent
        self.retryPolicy = retryPolicy
        self.decoder = decoder
    }

    // MARK: - Public API

    /// Issue `endpoint`, retry per policy, decode the 2xx body into `T`.
    /// Throws `ClinikoError` for every non-success path. The retry loop
    /// honours the endpoint's `allowsRetryOn5xx` flag for 5xx + transport;
    /// 429 always retries (up to the policy's budget) regardless of method.
    ///
    /// Callers that need the actual HTTP status (e.g. the audit ledger row
    /// in `TreatmentNoteExporter`) should use `sendWithStatus(_:)` instead.
    public func send<T: Decodable & Sendable>(_ endpoint: ClinikoEndpoint) async throws -> T {
        // Explicit annotation on the destructure so `T` flows from the
        // caller's expected return type into `sendWithStatus`'s generic
        // parameter — Swift can't infer it from a discarded tuple element.
        let (value, _): (T, Int) = try await sendWithStatus(endpoint)
        return value
    }

    /// Same retry / decode / error contract as `send(_:)`, but additionally
    /// surfaces the actual 2xx HTTP status the server returned alongside the
    /// decoded body. Issue [#58] — the audit ledger needs to record the
    /// observed status, not the documented constant. Most callers don't care
    /// about the status and should keep using `send(_:)`.
    public func sendWithStatus<T: Decodable & Sendable>(
        _ endpoint: ClinikoEndpoint
    ) async throws -> (T, Int) {
        guard let url = endpoint.buildURL(against: credentials.baseURL) else {
            // Closed-set inputs (enum-constrained shard host + endpoint cases)
            // make this unreachable; tests pin every-shard × every-endpoint
            // URL build. Treat reaching this branch as a programmer bug, not
            // a transport error — the user shouldn't see "transport error
            // (URLError code -1000)" for a code-side regression.
            // PHI: `pathTemplate` is documented log-safe (no bound IDs).
            preconditionFailure("ClinikoEndpoint.buildURL returned nil for closed-set input \(endpoint.pathTemplate)")
        }
        let request = buildRequest(url: url, endpoint: endpoint)

        var attempt = 0
        while true {
            let outcome: AttemptOutcome<T> = await runAttempt(
                request: request,
                endpoint: endpoint,
                attempt: attempt
            )
            switch outcome {
            case .success(let value, let status):
                return (value, status)
            case .terminal(let error):
                throw error
            case .retry(let delay):
                try await retryPolicy.sleep(delay)
                attempt += 1
            }
        }
    }

    // MARK: - Attempt execution

    /// Outcome of a single network attempt. `success` returns the decoded
    /// body alongside the actual 2xx HTTP status (so `sendWithStatus(_:)`
    /// can thread it to callers that audit on it); `terminal` is an error
    /// the caller will rethrow; `retry` re-enters the loop after the named
    /// delay.
    private enum AttemptOutcome<T> {
        case success(T, Int)
        case terminal(ClinikoError)
        case retry(TimeInterval)
    }

    private func runAttempt<T: Decodable & Sendable>(
        request: URLRequest,
        endpoint: ClinikoEndpoint,
        attempt: Int
    ) async -> AttemptOutcome<T> {
        let methodLog = endpoint.method.rawValue
        let pathTemplate = endpoint.pathTemplate
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                logger.error(
                    "ClinikoClient: \(methodLog, privacy: .public) \(pathTemplate, privacy: .public) non-HTTP response"
                )
                return .terminal(.nonHTTPResponse)
            }
            logger.info(
                "ClinikoClient: \(methodLog, privacy: .public) \(pathTemplate, privacy: .public) status=\(http.statusCode, privacy: .public) attempt=\(attempt, privacy: .public)"
            )
            return classifyResponse(T.self, data: data, http: http, endpoint: endpoint, attempt: attempt)
        } catch is CancellationError {
            return .terminal(.cancelled)
        } catch let urlError as URLError where urlError.code == .cancelled {
            return .terminal(.cancelled)
        } catch let urlError as URLError {
            return classifyTransportError(urlError, endpoint: endpoint, attempt: attempt)
        } catch {
            // Catch-all for non-URLError, non-Cancellation throws. Capture
            // the bridged `NSError` domain + code so a CFNetwork-layer
            // failure (captive-portal proxy, NSPOSIXErrorDomain, etc.)
            // leaves a triage trail. `domain` is a constant string; `code`
            // is an Int — both structural / non-PHI. We deliberately do
            // **not** log `localizedDescription`, which can carry localised
            // PHI-adjacent text.
            let typeName = String(reflecting: Swift.type(of: error))
            let nsError = error as NSError
            logger.error(
                "ClinikoClient: \(methodLog, privacy: .public) \(pathTemplate, privacy: .public) unexpected error type=\(typeName, privacy: .public) domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)"
            )
            return .terminal(.transport(.unknown))
        }
    }

    // MARK: - Response classification

    /// Map a successful URLSession round-trip (we got an `HTTPURLResponse`)
    /// into a success / terminal / retry outcome based on status.
    private func classifyResponse<T: Decodable & Sendable>(
        _ type: T.Type,
        data: Data,
        http: HTTPURLResponse,
        endpoint: ClinikoEndpoint,
        attempt: Int
    ) -> AttemptOutcome<T> {
        let status = http.statusCode
        switch status {
        case 200..<300:
            return decodeOutcome(T.self, from: data, status: status)
        case 401: return .terminal(.unauthenticated)
        case 403: return .terminal(.forbidden)
        case 404: return .terminal(.notFound(resource: endpoint.resource))
        case 422: return .terminal(.validation(fields: parseValidationErrors(from: data)))
        case 429: return classifyRateLimit(http: http, attempt: attempt)
        case 500..<600: return classifyServerError(status: status, endpoint: endpoint, attempt: attempt)
        default:
            // 1xx / 3xx / unclassified 4xx — surface as `.server(status:)`
            // but flag 3xx specifically because URLSession follows
            // same-origin redirects by default; a 3xx that survives to here
            // usually means a captive portal injecting a login redirect or
            // a Cliniko shard migration the user hasn't picked up yet.
            // Worth a structural log so the triage path doesn't read this
            // as "Cliniko is broken."
            if (300..<400).contains(status) {
                logger.error(
                    "ClinikoClient: \(endpoint.method.rawValue, privacy: .public) \(endpoint.pathTemplate, privacy: .public) unexpected redirect status=\(status, privacy: .public) — possible captive portal or shard migration"
                )
            } else {
                logger.error(
                    "ClinikoClient: \(endpoint.method.rawValue, privacy: .public) \(endpoint.pathTemplate, privacy: .public) unclassified status=\(status, privacy: .public)"
                )
            }
            return .terminal(.server(status: status))
        }
    }

    private func decodeOutcome<T: Decodable & Sendable>(
        _ type: T.Type,
        from data: Data,
        status: Int
    ) -> AttemptOutcome<T> {
        do {
            let value = try decodeBody(T.self, from: data)
            return .success(value, status)
        } catch let error as ClinikoError {
            return .terminal(error)
        } catch {
            // Swift's catch-exhaustiveness rule forces a fallback even
            // though `decodeBody` only throws `ClinikoError`. If a future
            // refactor makes it throw something else, we surface it as a
            // structural decoding failure (not a transport failure) so the
            // UI doesn't lie about the failure layer.
            let typeName = String(describing: T.self)
            logger.error(
                "ClinikoClient: decodeOutcome unexpected non-ClinikoError type=\(String(reflecting: Swift.type(of: error)), privacy: .public)"
            )
            return .terminal(.decoding(typeName: typeName))
        }
    }

    private func classifyRateLimit<T>(http: HTTPURLResponse, attempt: Int) -> AttemptOutcome<T> {
        let retryAfter = retryAfterSeconds(from: http)
        guard attempt < retryPolicy.maxRetries else {
            return .terminal(.rateLimited(retryAfter: retryAfter))
        }
        // Floor any honoured `Retry-After` at the policy's own delay so a
        // misbehaving server emitting `Retry-After: 0` (or negative) can't
        // make us hammer back-to-back. Still honour values *above* the
        // policy floor — that's the server saying "wait longer than you
        // planned to."
        let policyDelay = retryPolicy.delays[attempt]
        let delay = max(retryAfter ?? policyDelay, policyDelay)
        return .retry(delay)
    }

    private func classifyServerError<T>(
        status: Int,
        endpoint: ClinikoEndpoint,
        attempt: Int
    ) -> AttemptOutcome<T> {
        guard endpoint.isIdempotent, attempt < retryPolicy.maxRetries else {
            return .terminal(.server(status: status))
        }
        return .retry(retryPolicy.delays[attempt])
    }

    private func classifyTransportError<T>(
        _ urlError: URLError,
        endpoint: ClinikoEndpoint,
        attempt: Int
    ) -> AttemptOutcome<T> {
        let methodLog = endpoint.method.rawValue
        let pathTemplate = endpoint.pathTemplate
        if endpoint.isIdempotent, attempt < retryPolicy.maxRetries {
            return .retry(retryPolicy.delays[attempt])
        }
        logger.error(
            "ClinikoClient: \(methodLog, privacy: .public) \(pathTemplate, privacy: .public) transport code=\(urlError.code.rawValue, privacy: .public) attempt=\(attempt, privacy: .public)"
        )
        return .terminal(.transport(urlError.code))
    }

    // MARK: - Private

    private func buildRequest(url: URL, endpoint: ClinikoEndpoint) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(credentials.basicAuthHeaderValue, forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        if let body = endpoint.body {
            request.httpBody = body
            request.setValue(endpoint.contentType ?? "application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func decodeBody<T: Decodable & Sendable>(_ type: T.Type, from data: Data) throws -> T {
        // `EmptyResponse` is the marker the caller passes when the response
        // body should be ignored — both for 204 (no body) and for 200/201
        // responses where the caller doesn't care about the payload. We
        // short-circuit so neither case fails decode.
        if T.self == EmptyResponse.self, let empty = EmptyResponse() as? T {
            return empty
        }
        let typeName = String(describing: T.self)
        do {
            return try decoder.decode(T.self, from: data)
        } catch let decodingError as DecodingError {
            // `DecodingError.localizedDescription` and the associated
            // `CodingKey` paths can echo JSON keys, which are PHI-adjacent
            // for some Cliniko payloads. The case **tag** alone
            // (`keyNotFound`, `typeMismatch`, etc.) is structural, not
            // PHI — log the tag so triage knows the failure shape without
            // ever interpolating the underlying value.
            let kind = decodingErrorKind(decodingError)
            logger.error(
                "ClinikoClient: decode failed type=\(typeName, privacy: .public) kind=\(kind, privacy: .public)"
            )
            throw ClinikoError.decoding(typeName: typeName)
        } catch {
            // Non-DecodingError on a Decodable.decode call should be
            // unreachable, but never silently relabel — log the type and
            // surface as `.decoding` not `.transport`.
            let errorTypeName = String(reflecting: Swift.type(of: error))
            logger.error(
                "ClinikoClient: decode failed (non-DecodingError) type=\(typeName, privacy: .public) error=\(errorTypeName, privacy: .public)"
            )
            throw ClinikoError.decoding(typeName: typeName)
        }
    }

    private func decodingErrorKind(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound: return "keyNotFound"
        case .typeMismatch: return "typeMismatch"
        case .valueNotFound: return "valueNotFound"
        case .dataCorrupted: return "dataCorrupted"
        @unknown default: return "unknownKind"
        }
    }

    private func retryAfterSeconds(from response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if let seconds = TimeInterval(trimmed) {
            return seconds
        }
        // RFC 7231 §7.1.3 also allows the HTTP-date form (e.g.
        // "Wed, 21 Oct 2026 07:28:00 GMT"), which Cliniko emits during
        // scheduled-maintenance windows. Parse it and convert to a forward-
        // looking interval; floor at zero in case the server-clock drifted.
        if let date = httpDateFormatter.date(from: trimmed) {
            return max(0, date.timeIntervalSinceNow)
        }
        logger.error(
            "ClinikoClient: 429 with unparseable Retry-After (length=\(trimmed.count, privacy: .public))"
        )
        return nil
    }

    private func parseValidationErrors(from data: Data) -> [String: [String]] {
        // Best-effort decode of the two response shapes Cliniko documents
        // for 422. A fresh `JSONDecoder()` (rather than `self.decoder`) is
        // intentional: the validation envelope keys are already lowercase
        // and we don't want `convertFromSnakeCase` rewriting `errors` →
        // `errors` (no-op today, but a footgun if a future endpoint case
        // adds `error_code` etc.).
        struct DictShape: Decodable { let errors: [String: [String]]? }
        if let dict = try? JSONDecoder().decode(DictShape.self, from: data),
           let errors = dict.errors {
            return errors
        }
        struct ListShape: Decodable {
            let errors: [Item]?
            struct Item: Decodable {
                let field: String?
                let message: String?
            }
        }
        if let list = try? JSONDecoder().decode(ListShape.self, from: data),
           let items = list.errors {
            var result: [String: [String]] = [:]
            for item in items {
                let key = item.field ?? "_"
                let message = item.message ?? ""
                result[key, default: []].append(message)
            }
            return result
        }
        // Both documented shapes failed. Log a structural marker so we can
        // detect a third undocumented shape in production without ever
        // logging the body. `data.count` and the first byte are non-PHI
        // and tell triage "is it JSON-shaped at all? object or array?".
        let firstByte: String = data.first.map { String(format: "0x%02x", $0) } ?? "empty"
        logger.error(
            "ClinikoClient: 422 body parse failed; bytes=\(data.count, privacy: .public) firstByte=\(firstByte, privacy: .public)"
        )
        return [:]
    }
}

/// Marker type the caller can pass to `ClinikoClient.send(_:) as Empty…` when
/// the response body is irrelevant (e.g. probing connectivity, or a 204
/// response). Decoding short-circuits so empty bodies don't fail.
public struct EmptyResponse: Decodable, Sendable, Equatable {
    public init() {}
}
