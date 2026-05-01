# AGENTS.md — `Sources/Services/Cliniko/`

## Purpose

This subdirectory is the Cliniko integration layer: HTTP client,
typed endpoints + errors, Keychain-backed credential storage, regional
shard handling, and the metadata-only export audit ledger. **All
network egress from the app passes through here** — every byte that
leaves the doctor's Mac for Cliniko is built, signed, and logged by
the types in this folder. Nowhere else in `Sources/` should construct
a Cliniko `URLRequest` directly.

For protocol-level reference (auth, error mapping, retry policy,
endpoints, audit shape) see
[`../../../.claude/references/cliniko-api.md`](../../../.claude/references/cliniko-api.md).
For the PHI rules every file here enforces, see
[`../../../.claude/references/phi-handling.md`](../../../.claude/references/phi-handling.md).

---

## Key types

| File | Role |
|---|---|
| `ClinikoClient.swift` | `actor` wrapping `URLSession`. Single public `send<T>(_:)` method: builds an authenticated request from a `ClinikoEndpoint`, applies the retry policy, decodes 2xx into `T`, surfaces `ClinikoError` for everything else. Handles `Retry-After` (numeric + RFC 7231 HTTP-date), 429 / 5xx classification, transport / cancellation. |
| `ClinikoEndpoint.swift` | Closed-set enum of in-scope endpoints (`usersMe`, `patientSearch`, `patientAppointments`, `createTreatmentNote`). Owns method, path template (log-safe), resource discriminator for 404, body / content-type, `isIdempotent` (drives 5xx + transport retry policy), and `buildURL(against:)`. |
| `ClinikoError.swift` | Typed error set: `.unauthenticated`, `.forbidden`, `.notFound(resource:)`, `.validation(fields:)`, `.rateLimited(retryAfter:)`, `.server(status:)`, `.transport(URLError.Code)`, `.cancelled`, `.decoding(typeName:)`, `.nonHTTPResponse`. All payloads are structural — the whole enum is safe to interpolate at `OSLog` `.public`. |
| `ClinikoCredentialStore.swift` | `actor` adapter over a `SecureStore` for the API key (Keychain) plus a `nonisolated` `UserDefaults` accessor for the shard. Owns the `serviceName`, account, and shard-key constants. Note: `KeychainSecureStore` (the generic Keychain wrapper) lives at `../KeychainSecureStore.swift` because it is not Cliniko-specific. |
| `ClinikoShard.swift` | Regional-shard enum (`au1` … `eu1`) with `apiHost` + `displayName`. The single source of truth for the subdomain — no hostname strings live elsewhere in the codebase. |
| `ClinikoAuthProbe.swift` | Standalone `actor` issuing `GET /user` (Cliniko's authenticated-user endpoint) for the Settings "Test connection" button (#7). Predates `ClinikoClient`; will likely fold into `client.send(.usersMe)` in a follow-up. The `usersMe` case name is preserved for source-compat — only the wire path is `/user`. The earlier `/users/me` wiring 404'd; see #88. |
| `ClinikoPatientService.swift` | `actor` conforming to the actor-constrained protocol `ClinikoPatientSearching`. Thin wrapper around `client.send(.patientSearch(query:))`. The picker debounces; this layer is stateless. |
| `ClinikoAppointmentService.swift` | `actor` conforming to `ClinikoAppointmentLoading`. Computes a UTC-pinned `[reference − 7 days, reference + 1 day)` window and delegates to `client.send(.patientAppointments(...))`. |
| `TreatmentNoteExporter.swift` | `actor` orchestrating the `POST /treatment_notes` flow: composes the wire payload from `StructuredNotes` + selected manipulations, calls `client.send(.createTreatmentNote(body:))`, and on a successful 201 writes a metadata-only `AuditRecord`. Audit-write failure is non-fatal (returns `ExportOutcome(auditPersisted: false)`) so a ledger error never tempts a duplicate POST. |
| `AuditStore.swift` | `AuditStore` protocol + `LocalAuditStore` (JSONL append to `~/Library/Application Support/<bundle>/audit.jsonl`, file mode `0o600`, line-level atomic) + `InMemoryAuditStore` (test fake with optional `recordHook` for failure injection). Carries the `AuditRecord` schema. |

---

## Common pitfalls

### PHI in logs

**Never** log request bodies, response bodies, bound URLs, patient
names, query strings, or `String(describing: error)` — anywhere in
this folder. `OSLog` `privacy: .public` is reserved for: HTTP method,
**path template** (`pathTemplate` on `ClinikoEndpoint`, never the
resolved URL), status code, latency, error-case name, decode-target
type name, `URLError.Code.rawValue`, and `NSError.domain` /
`NSError.code`. This is non-negotiable — see
[`phi-handling.md`](../../../.claude/references/phi-handling.md). When
in doubt, drop the log.

### `AuditStore` invariants

`AuditRecord` carries metadata only: `timestamp`, `patient_id`,
`appointment_id`, `note_id`, `cliniko_status`, `app_version`. **Never**
the SOAP body, transcript, patient name, or any free-text field. The
type system enforces this — every field is a primitive (`Date`, `Int`,
`String`-shaped via `OpaqueClinikoID`, `Int`, `String`). If you find
yourself wanting to add a `String` field that could carry note content,
stop: the on-disk schema is pinned by
[`cliniko-api.md`](../../../.claude/references/cliniko-api.md) §Audit
and `AuditStoreTests.line_keysMatchWhitelist` will fail the moment the
key set widens. Coordinate a paired update of the reference doc + the
EPIC's locked-decisions table before changing the shape.

### Authorization header

The API key lives in Keychain only, namespaced as
`service: "com.speechtotext.cliniko"`, `account: "api_key"`, with
accessibility `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (no iCloud
sync). **Never** in `UserDefaults`, **never** logged (not even
obfuscated), **never** round-tripped back to the SwiftUI layer once
stored. Callers needing to issue a request fetch a `ClinikoCredentials`
value from `ClinikoCredentialStore.loadCredentials()` and hand it to
`ClinikoClient`'s initialiser.

### Retry policy

Only 429 retries unconditionally (up to the `RetryPolicy.maxRetries`
budget, honouring `Retry-After` floored at the policy's own delay).
5xx + transport retry **only if `endpoint.isIdempotent` is true** —
`createTreatmentNote` is **not** idempotent because we cannot tell
whether a failed POST landed server-side, and a duplicate would
double-write a clinical record. The full table lives in
[`cliniko-api.md`](../../../.claude/references/cliniko-api.md)
§"Retry policy".

### Cliniko date offsets — do NOT use `.iso8601` decoder strategy

Cliniko's AU shards return ISO8601 timestamps in **three** distinct
shapes the global `JSONDecoder.DateDecodingStrategy.iso8601` does not
all handle:

- `2026-04-25T09:00:00Z` (UTC) — works.
- `2026-04-25T19:00:00+10:00` (RFC3339, with colon) — works.
- `2026-04-25T19:00:00+1000` (ISO8601 basic offset, no colon) —
  **rejected by `ISO8601DateFormatter` regardless of options**.
- Plus any of the above with fractional seconds (`2026-04-25T09:00:00.123Z`)
  which require `[.withInternetDateTime, .withFractionalSeconds]` —
  also not the strategy default.

**Rule** (#129): for any new endpoint that returns Cliniko-side
datetimes, decode the wire field as raw `String` in the DTO and parse
it through `ClinikoDateParser` in the `toDomainModel(parser:)`
mapping. Do NOT add `.iso8601` (or any custom date strategy) to
`ClinikoClient.defaultDecoder` — every endpoint that already worked
(Patient `date_of_birth`, audit timestamps) does so because the field
is `String`, not `Date`. Adding a strategy would cascade into hidden
parse failures on the AU `+1000` form and silently degrade existing
endpoints.

The `ClinikoAppointmentService` flow is the canonical example:
`Sources/Models/ClinikoAppointmentDTO.swift` decodes `starts_at` /
`ends_at` / `cancelled_at` / `archived_at` as `String?`, then
`ClinikoAppointmentService.recentAndTodayAppointments(...)` calls
`dto.toDomainModel(parser:)` to produce `[Appointment]` with parsed
`Date` fields.

`ClinikoClient.defaultDecoder` already sets `.iso8601` as its date
strategy. Every Cliniko endpoint we ship today decodes datetimes as
`String` in the DTO and parses via `ClinikoDateParser`, so the
strategy never fires — but don't *rely* on this. Don't *remove* the
strategy either: removing it would silently change behaviour for any
future `Date`-typed field added without a paired code review. The
right pattern for a new `Date` field is to add it as `String` in the
DTO and parse explicitly.

### Shard handling

**Never** hardcode `api.au1.cliniko.com` (or any subdomain) anywhere
in `Sources/`. Always derive from `ClinikoShard.apiHost` via
`ClinikoCredentials.baseURL`. The shard is also encoded as a suffix on
the API key (e.g. `MS-XXXXX-au1`) but v1 takes the explicit picker
route — auto-detection is a possible follow-up.

### Real HTTP status in audit rows: use `sendWithStatus(_:)`

`ClinikoClient` exposes two public entry points:

- `send<T>(_:) async throws -> T` — the common path; most call sites
  (patient search, appointment list, `/user`) don't care about the
  status and use this.
- `sendWithStatus<T>(_:) async throws -> (T, Int)` — additive overload
  that surfaces the actual 2xx status the server returned. Use this
  when the caller audits on the observed status (today: only
  `TreatmentNoteExporter`, which records it as `AuditRecord.clinikoStatus`).
  Don't reach for it elsewhere — the audit ledger contract is what
  motivates the tuple shape, and threading a status nobody reads adds
  noise. Issue #58.

---

## Testing notes

- **HTTP**: route `URLSession.data(for:)` through `URLProtocolStub`
  (`Tests/SpeechToTextTests/Utilities/URLProtocolStub.swift`) — a
  hand-rolled, zero-dependency `Sendable` `URLProtocol` subclass.
  Fixtures live under
  `Tests/SpeechToTextTests/Fixtures/cliniko/{requests,responses}/`.
- **HTTP from a Swift Testing `@Suite`**: also wrap each `@Test` body
  in `try await URLProtocolStubGate.shared.withGate { ... }`
  (`Tests/SpeechToTextTests/Utilities/URLProtocolStubGate.swift`).
  `URLProtocolStub` is a process-wide singleton and Swift Testing's
  `.serialized` trait is suite-local, so without the gate two HTTP-
  stubbed Swift Testing suites race across the suite boundary (PR #84
  CI commit `964d877`). XCTest classes here (`ClinikoClientTests`,
  `TreatmentNoteExporterTests`) do **not** need the gate; XCTest
  scheduling has coexisted with Swift Testing safely since #20.
  `Tests/SpeechToTextTests/Services/Cliniko/ClinikoStatusThreadingTests.swift`
  is the reference adopter — issue #85.
- **Credentials**: use `InMemorySecureStore` (actor fake, never imports
  `Security`) for `ClinikoCredentialStore` tests.
- **Real Cliniko / real Keychain**: **never** in CI. Goldens that need
  real services are gated behind env vars and run only in nightly /
  remote-Mac.
- **`AuditStore` byte-shape pin**:
  `AuditStoreTests.line_pins_opaque_id_byte_shape` asserts the JSONL
  encoding of `OpaqueClinikoID` (#59) stays a bare string, not the
  `RawRepresentable` synthesised wrapping object. If you change
  `AuditRecord`'s `Codable` strategy or `LocalAuditStore.makeEncoder()`
  (`.sortedKeys`, `.iso8601`), this test will fail by design — coordinate
  with `cliniko-api.md` §Audit before regenerating.
- Canonical Swift Testing idiom + tag conventions:
  [`testing-conventions.md`](../../../.claude/references/testing-conventions.md).
  This folder's tests are tagged `.fast` and live in
  `Tests/SpeechToTextTests/Services/`.

PHI-free fixtures only: every `<patient>`, `<note_id>`,
`<appointment_id>` is synthetic. Never copy production data, even
redacted.

---

## Related

- [`../../../.claude/references/cliniko-api.md`](../../../.claude/references/cliniko-api.md) — endpoints, auth, error mapping, retry table, audit schema.
- [`../../../.claude/references/phi-handling.md`](../../../.claude/references/phi-handling.md) — PHI rules every log line in this folder follows.
- [`../../../.claude/references/testing-conventions.md`](../../../.claude/references/testing-conventions.md) — `URLProtocolStub`, `InMemorySecureStore`, fixture layout, tags.
- Sister AGENTS.md (when they land — tracked in #17):
  [`../ClinicalNotes/AGENTS.md`](../ClinicalNotes/AGENTS.md),
  [`../../Views/ClinicalNotes/AGENTS.md`](../../Views/ClinicalNotes/AGENTS.md).
- [EPIC #1 — Clinical Notes Mode](https://github.com/CloudbrokerAz/mac-speech-to-text/issues/1).
- [Issue #58 — thread real HTTP status into `AuditStore` rows](https://github.com/CloudbrokerAz/mac-speech-to-text/issues/58).
