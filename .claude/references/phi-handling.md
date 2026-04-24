# PHI Handling Policy

> **Load this when:** adding or reviewing any code path that touches a
> patient transcript, a generated SOAP note, a patient record, or
> anything that could be PHI. Load before writing logs, crash reports,
> telemetry, audit entries, test fixtures, or anything external (Slack,
> GitHub issues, etc.).

"PHI" in this project means the narrow set of patient-related data the
app sees: consultation transcripts, generated SOAP notes, suggested
manipulations, excluded-content snippets, patient demographics (name,
DOB, contact), and `treatment_note` bodies. Chiropractic clinics in
AU/UK/US are subject to health-record-handling obligations regardless
of whether HIPAA applies directly — treat everything as sensitive.

---

## Where PHI may live

Exactly two places:

1. **In-memory within the active `ClinicalSession`.** Cleared on export
   success, app quit, or the inactivity-timeout threshold. Never
   serialised to disk, UserDefaults, or any cache. See `SessionStore`
   (issue #2).
2. **The HTTPS body at the moment of `POST /treatment_notes`.** Goes
   directly from the doctor's Mac to the doctor's Cliniko tenant over
   TLS. Nowhere else.

---

## Where PHI MUST NOT appear

- **Logs / `OSLog`.** Annotate anything remotely PHI-adjacent with
  `privacy: .private`. `privacy: .public` is reserved for structural
  values (error-case names, HTTP status, path templates, file paths that
  don't contain patient IDs).
- **Crash reports.** Any `fatalError` / `preconditionFailure` message
  must not interpolate PHI. Prefer inert messages (e.g.
  `"SessionStore invariant violated"`) that the stack trace itself
  explains.
- **Audit log (`audit.jsonl`).** Metadata only: timestamp, patient_id
  (opaque string), appointment_id, note_id from response, HTTP status,
  app version. Never note body, transcript, or patient name. See
  `.claude/references/cliniko-api.md`.
- **Test fixtures.** Fixtures under `Tests/SpeechToTextTests/Fixtures/`
  must use obviously-synthetic data (sample names, `@example.test`
  domains, placeholder IDs). Never copy production data, even redacted.
- **Issue comments, PR descriptions, Slack messages, subagent prompts.**
  Summarise in structural terms (e.g. "patient search returned zero
  results in the UI test with a known-good query") instead of echoing
  the patient data.
- **External tooling.** The `/ultrareview` command, Codecov, error
  aggregators, GitHub Actions logs — nothing with PHI leaves the
  device. If a tool needs a sample payload, use a fixture.
- **Disk outside Keychain.** Cliniko API keys + shard live in Keychain /
  UserDefaults respectively (the subdomain is not PHI). No other
  persistent store may contain patient-adjacent data in v1.

---

## When a log line is ambiguous

Rule of thumb: **if a reviewer's first reaction is "wait, can we log
that?", the answer is no.**

```swift
// Fine — all structural.
logger.info("cliniko POST /treatment_notes status=\(status, privacy: .public) latency=\(ms, privacy: .public)ms")

// NOT fine — response body can carry note_id AND the echoed payload.
logger.debug("cliniko response: \(responseString)")

// NOT fine — subtle: even the count could be inferred as PHI if paired with appointment timing.
logger.info("patient search for \"\(query)\" returned \(results.count) hits")
```

When in doubt, drop the log. Tests should exercise the happy path —
logs are for ops, not debugging.

---

## Crash-path hygiene

- `fatalError` messages, `preconditionFailure` messages, and
  `assertionFailure` messages are visible in crash reports and Console.
- Treat them as logs: no PHI interpolation.
- Prefer `guard … else { fatalError("SessionStore: active session lost") }`
  over `fatalError("Session \(session.id) for \(session.patientName) lost")`.

---

## Test guardrails

Every service that touches PHI gets a test asserting the PHI-free
invariant:

- `AuditStore` — assert exported keys are a fixed whitelist; any
  transcript-looking string rejected.
- `ClinicalNotesProcessor` — assert no prompt or response data leaks
  into `logger` at `.default` or above (verify with
  `OSLogMessageReconstructor`-style test or by asserting the redaction
  helper is called).

These assertions are enumerated in each consumer's acceptance criteria.

---

## Disclaimer interaction

The one-time "not a diagnostic tool" disclaimer (#12) exists in part to
reinforce practitioner responsibility. Its acknowledgement flag is a
UserDefaults boolean — not PHI, no special handling needed.

---

## Jurisdictions the app is likely used in

- **Australia** — Privacy Act 1988, My Health Records Act. Clinic-
  owned data; practitioner responsible.
- **UK** — UK GDPR, Data Protection Act 2018. Special-category health
  data rules.
- **US** — HIPAA applies if the practitioner is a covered entity or
  processes via a covered entity. Most solo chiropractic practices are
  not strictly covered, but the bar is still "act as if you are".

None of the above allow patient data to traverse an unrelated third
party. Keeping everything on-device + direct-to-Cliniko-tenant is the
compliance-safe default.
