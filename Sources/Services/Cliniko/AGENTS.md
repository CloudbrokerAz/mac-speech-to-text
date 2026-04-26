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
| `ClinikoAuthProbe.swift` | Standalone `actor` issuing `GET /users/me` for the Settings "Test connection" button (#7). Predates `ClinikoClient`; will likely fold into `client.send(.usersMe)` in a follow-up. |
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

### Shard handling

**Never** hardcode `api.au1.cliniko.com` (or any subdomain) anywhere
in `Sources/`. Always derive from `ClinikoShard.apiHost` via
`ClinikoCredentials.baseURL`. The shard is also encoded as a suffix on
the API key (e.g. `MS-XXXXX-au1`) but v1 takes the explicit picker
route — auto-detection is a possible follow-up.

### Known limitation: `ClinikoClient.send<T>` doesn't thread the real HTTP status into audit rows

`TreatmentNoteExporter` currently writes `clinikoStatus: 201` as a
documented-contract constant rather than reading the actual response
status, because `send<T>` discards the `HTTPURLResponse` after
classifying 2xx into the success path. Tracked as
[issue #58](https://github.com/CloudbrokerAz/mac-speech-to-text/issues/58);
when that lands, replace the literal in
`TreatmentNoteExporter.export(...)` with the threaded value. Until
then, the audit row's status is the documented value, not the observed
one.

---

## Testing notes

- **HTTP**: route `URLSession.data(for:)` through `URLProtocolStub`
  (`Tests/SpeechToTextTests/Utilities/URLProtocolStub.swift`) — a
  hand-rolled, zero-dependency `Sendable` `URLProtocol` subclass.
  Fixtures live under
  `Tests/SpeechToTextTests/Fixtures/cliniko/{requests,responses}/`.
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
