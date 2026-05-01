import Foundation

/// Parses Cliniko's ISO8601 datetime strings into `Date`.
///
/// **Why a custom parser** (issue #129): Swift's
/// `JSONDecoder.DateDecodingStrategy.iso8601` uses `ISO8601DateFormatter`
/// configured with `[.withInternetDateTime]` only. Cliniko AU shards
/// emit timestamps in two distinct shapes the default strategy does not
/// handle cleanly:
///
/// - **`+10:00` form (RFC3339, with colon)**: e.g. `2026-04-25T19:00:00+10:00`.
///   `ISO8601DateFormatter` with `[.withInternetDateTime]` accepts this.
/// - **`+1000` form (ISO8601 basic offset, no colon)**: e.g.
///   `2026-04-25T19:00:00+1000`. `ISO8601DateFormatter` rejects this
///   regardless of options. We fall back to a `DateFormatter` with the
///   matching pattern.
/// - **Fractional seconds**: e.g. `2026-04-25T09:00:00.123Z`. Requires
///   `[.withInternetDateTime, .withFractionalSeconds]`.
///
/// The parser tries each path in order — fractional ISO → bare ISO →
/// `DateFormatter` for `+HHMM` shapes — and throws
/// `ClinikoError.decoding(typeName: "Date")` if every parse fails. The
/// thrown error never carries the input string so PHI-adjacent
/// timestamps (an appointment time + a known patient context) cannot
/// leak through `localizedDescription`.
///
/// PHI: the parser does not log. The caller (`ClinikoAppointmentDTO.toDomainModel`)
/// catches and re-throws via the typed `ClinikoError` set; the client
/// emits its kind-tag log without the value.
struct ClinikoDateParser: Sendable {

    /// Parse an ISO8601 datetime string into `Date`. Tries:
    /// 1. `ISO8601DateFormatter` with fractional-seconds + internet date-time.
    /// 2. `ISO8601DateFormatter` with internet date-time only.
    /// 3. `DateFormatter` with `yyyy-MM-dd'T'HH:mm:ssZZZZ` (covers `+1000`).
    /// 4. `DateFormatter` with `yyyy-MM-dd'T'HH:mm:ss.SSSZZZZ` (covers
    ///    `+1000` with fractional seconds).
    func parse(_ input: String) throws -> Date {
        // Cascade order: try plain ISO first because the vast majority
        // of Cliniko payloads carry no fractional seconds; pay the
        // happy-path cost on the most common shape. Fractional ISO is
        // strict — it requires fractional seconds to be present — so
        // it cannot accidentally consume a non-fractional input that
        // pass 1 already rejected. Same logic for the basic-offset
        // formatters: plain before fractional.
        if let date = Self.iso8601Plain.date(from: input) { return date }
        if let date = Self.iso8601Fractional.date(from: input) { return date }
        if let date = Self.basicOffsetPlain.date(from: input) { return date }
        if let date = Self.basicOffsetFractional.date(from: input) { return date }
        throw ClinikoError.decoding(typeName: "Date")
    }

    // MARK: - Formatters

    // `ISO8601DateFormatter` is thread-safe per Apple's docs (the relevant
    // header explicitly states all methods are safe to call concurrently).
    // `DateFormatter` is also documented as thread-safe on macOS 10.9+.
    // Both are static `let` so we pay the construction cost exactly once.

    private static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601Plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let basicOffsetPlain: DateFormatter = {
        let formatter = DateFormatter()
        // `ZZZZ` accepts `+HHMM` (no colon) AND `+HH:MM` forms
        // empirically on macOS 26 (verified by the
        // `parses_basicOffset_plain` test); strict ICU/TR35
        // interpretation is "long localised GMT" but Foundation's
        // `DateFormatter` is more lenient than the spec on the parse
        // side. The strict-RFC alternative would be `xxxx` (basic-form
        // `+HHMM` only). Either works for our cascade because
        // `+HH:MM` is already handled by `iso8601Plain`. Sticking with
        // `ZZZZ` for backwards compatibility with future devices that
        // emit the long-localised form. `Locale("en_US_POSIX")` is the
        // canonical fixed-format-parser locale per Apple's docs (rdar
        // #18377693 — without it, system locales with non-Gregorian
        // calendars would silently misparse). `isLenient = false` is
        // defence-in-depth — Foundation's default could flip in a
        // future release; pinning here keeps the parser strict.
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZ"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.isLenient = false
        return formatter
    }()

    private static let basicOffsetFractional: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZ"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.isLenient = false
        return formatter
    }()
}
