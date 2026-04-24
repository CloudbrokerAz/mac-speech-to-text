# Cliniko API Reference

> **Load this when:** writing or reviewing the Cliniko client layer
> (issue #8), the patient/appointment picker (#9), `treatment_note`
> export (#10), or the credential-management surface (#7). Also relevant
> when touching `AuditStore`.

Design reference for the Cliniko integration, informed by the similar
work in
[`CloudbrokerAz/epc-letter-generation`](https://github.com/CloudbrokerAz/epc-letter-generation/tree/main/Sources/Services)
and the [official Cliniko API docs](https://docs.api.cliniko.com/).

---

## Authentication

- **API key** (secret): stored in Keychain via the `SecureStore` protocol.
  - `SecureStore` service identifier: `"com.speechtotext.cliniko"`.
  - Account: `"api_key"`.
  - Accessibility: `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (no iCloud sync).
- **Shard / subdomain** (non-secret): stored in `UserDefaults`.
  - Example values: `au1`, `au2`, `au3`, `au4`, `uk1`, `uk2`, `ca1`, `us1`.
  - Used to build the base URL: `https://api.{shard}.cliniko.com/v1`.
- **Auth scheme**: HTTP Basic with `"{api_key}:"` (the empty password is
  deliberate — Cliniko uses the API key as the username).
- **Required headers** (per Cliniko docs):
  - `User-Agent: mac-speech-to-text/<version> (contact@example.test)` —
    Cliniko requires a contact email; plumb through a setting if needed.
  - `Accept: application/json`.

---

## Error mapping

`ClinikoClient.send(…)` must surface typed errors, not raw `URLError`:

| Cliniko response | Swift error |
|---|---|
| `401` | `.unauthenticated` — API key invalid or revoked. Route the user to the Cliniko settings sheet. |
| `403` | `.forbidden` — key is valid but lacks the needed scope / the practitioner can't see that patient. |
| `404` | `.notFound` — typed `.notFound(resource: Resource)` where `Resource` identifies patient / appointment / treatment_note. |
| `422` | `.validation(fields: [String: [String]])` — parse the error body. Show field-level messages in the UI. |
| `429` | `.rateLimited(retryAfter: TimeInterval)` — parse `Retry-After` header. The client should auto-retry (see Retry). |
| `5xx` | `.server(status: Int)` — retry per policy below. |
| Network / DNS / TLS | `.transport(Error)` — wrap the underlying error, don't swallow it. |

---

## Retry policy

- **Idempotent reads** (GET): up to 2 retries on 5xx / transport, exponential backoff (1s, 2s).
- **Writes** (POST/PATCH on `treatment_notes`): **no auto-retry on 5xx** to avoid duplicate notes. Surface the error; let the user re-confirm.
- **429**: honour `Retry-After`, up to 2 retries. UI shows a countdown.
- Retries live inside the `ClinikoClient` actor so callers don't have to think about it. 2 retries max across the whole stack.

---

## Redaction rules (PHI)

Logging around Cliniko calls must follow the PHI rules from
[`phi-handling.md`](phi-handling.md). Summary for this client:

- **OK to log**: HTTP method, path template (`/patients/:id`, not `/patients/12345`), status, latency, typed error case.
- **NEVER log**: request body, response body, patient first/last name, DOB, `treatment_note` content, API key (not even obfuscated), subdomain/shard (low-sensitivity but not needed).
- `OSLog` privacy annotation: default to `privacy: .private` for anything the code doesn't strictly own. `privacy: .public` is reserved for structural values (status, method, path template, error case name).

---

## Endpoints in scope for v1

| Endpoint | Method | Purpose | Issue |
|---|---|---|---|
| `/users/me` | GET | "Test connection" in the Cliniko settings UI | #7 |
| `/patients?q={term}` | GET | Patient picker search (debounced 300 ms) | #9 |
| `/patients/{id}/appointments?from=…&to=…` | GET | List recent + today's appointments for the chosen patient | #9 |
| `/treatment_notes` | POST | Submit the generated SOAP note (+ optional `appointment_id`) | #10 |

Schema details belong in fixture files under
`Tests/SpeechToTextTests/Fixtures/cliniko/`, not this doc.

---

## Tenant template variability

Cliniko `treatment_notes` are template-driven. Different clinics may have
different field layouts (custom fields for "Manipulations used",
different section names). Two decisions:

1. **v1 approach**: post the SOAP note as a single markdown/HTML body
   and let the clinic's template pull from it. This works for any
   template without clinic-specific mapping code.
2. **Future**: a clinic-side configuration file maps our `StructuredNotes`
   fields to a specific treatment-note template's custom fields. Deferred
   until we have a real clinic to pilot with.

---

## Audit

Every successful export writes a metadata-only line to
`AuditStore` (Application Support, `audit.jsonl`):

```json
{
  "timestamp": "2026-04-24T12:34:56Z",
  "patient_id": "12345",
  "appointment_id": "67890",
  "note_id": "from-response",
  "cliniko_status": 201,
  "app_version": "0.x.y"
}
```

**No transcript, no SOAP body, no patient name.** The test matrix for
`AuditStore` must assert no such field ever leaks (see #10's acceptance).

---

## Reference implementations

- Networking layer mirrors patterns from
  [`epc-letter-generation/Sources/Services/Networking/`](https://github.com/CloudbrokerAz/epc-letter-generation/tree/main/Sources/Services/Networking).
- Keychain credentials mirror
  [`epc-letter-generation/Sources/Services/KeychainCredentialStore.swift`](https://github.com/CloudbrokerAz/epc-letter-generation/blob/main/Sources/Services/KeychainCredentialStore.swift).
- Audit log mirrors
  [`epc-letter-generation/Sources/Services/AuditStore.swift`](https://github.com/CloudbrokerAz/epc-letter-generation/blob/main/Sources/Services/AuditStore.swift).

---

## Related files (once implemented)

- `Sources/Services/Cliniko/ClinikoClient.swift` — actor + URLSession.
- `Sources/Services/Cliniko/ClinikoEndpoint.swift` — endpoint enum.
- `Sources/Services/Cliniko/ClinikoError.swift` — typed errors.
- `Sources/Services/AuditStore.swift` — metadata-only audit log.
- `Tests/SpeechToTextTests/Fixtures/cliniko/` — request + response goldens.
