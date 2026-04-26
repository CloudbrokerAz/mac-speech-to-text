# AGENTS.md — `Sources/Services/ClinicalNotes/`

> **Load this when:** writing or reviewing anything in
> `Sources/Services/ClinicalNotes/` — the post-recording SOAP-note
> pipeline. For HTTP / Cliniko, see [`../Cliniko/AGENTS.md`](../Cliniko/AGENTS.md).
> For the review surface, see [`../../Views/ClinicalNotes/AGENTS.md`](../../Views/ClinicalNotes/AGENTS.md).

## Purpose

This subdirectory owns the **transcript → structured SOAP →
practitioner-ready ViewModel** seam. It sits between the recording
layer (FluidAudio → `RecordingSession`) and the Cliniko export layer
(`../Cliniko/`). Nothing in here makes network calls, nothing in here
writes to disk, and nothing in here logs PHI — see
[`../../../.claude/references/phi-handling.md`](../../../.claude/references/phi-handling.md).

The pipeline:

1. `SessionStore` ingests a completed `RecordingSession`.
2. `ClinicalNotesProcessor` runs the transcript through an
   `LLMProvider`, validates the response against the schema, and
   produces a `StructuredNotes` (or a fallback sentinel).
3. The practitioner edits the draft in `ReviewScreen`; manipulation
   IDs resolve via `ManipulationsRepository`.
4. On Export, `ExportFlowCoordinator` builds an `ExportFlowViewModel`
   wired to the Cliniko exporter.

---

## Key types

| Type | Role |
|---|---|
| `SessionStore` | `@MainActor` `@Observable`. Single-writer owner of the active `ClinicalSession` (transcript, draft, patient/appointment selection). Session-only — `clear()` on export success, quit, cancel, or `checkIdleTimeout()`. |
| `ClinicalNotesProcessor` | `actor`. Drives transcript → `StructuredNotes` via `LLMProvider`. **Retry-once contract** on schema-invalid responses; falls back to raw transcript on second failure. Never throws — all failures resolve to `Outcome.rawTranscriptFallback(reason:)` with a structural sentinel. |
| `ClinicalNotesPromptBuilder` | `struct` (`Sendable`). Pure-logic prompt assembly + JSON schema validation. Loads `Resources/Prompts/soap_v1.txt`; substitutes `{{manipulations_list}}` then `{{transcript}}`. `validate(json:)` returns `Result<RawLLMDraft, SchemaError>`; tolerates code fences + trailing commentary, rejects malformed payloads with **PHI-safe** structural errors only. |
| `LLMProvider` (protocol) | `Actor`-constrained. `generate(prompt:options:)` → `String`; `nonisolated generateStream(...)` for incremental UIs. Concrete: `MLXGemmaProvider` (production) / `MockLLMProvider` (tests). See [`../../../.claude/references/concurrency.md`](../../../.claude/references/concurrency.md) §6 for why Actor-constrained — actors cannot be subclassed, so mocks must conform via the protocol. |
| `LLMOptions` | `Sendable` struct of sampling knobs. **Defaults are deterministic**: `temperature: 0`, `seed: 42`. The processor passes these unchanged so the same transcript yields the same JSON across runs — the assumption the LLM golden tests rely on. |
| `ManipulationsRepository` | Immutable value type; `Sendable` by construction. Loads the bundled chiropractic-manipulations taxonomy (`Resources/Manipulations/placeholder.json` for v1; one-file swap when the real Cliniko taxonomy lands). Consumed by the prompt builder, the ReviewScreen checklist, and the Cliniko export mapping. Not PHI. |
| `ExportFlowCoordinator` | `@MainActor` singleton (`.shared`). Factory that wires `SessionStore` + `ManipulationsRepository` + `TreatmentNoteExporter` + AppKit callbacks (`closeReviewWindow`, `openClinikoSettings`) into a fresh `ExportFlowViewModel` per Export tap. Configured once by `AppState.init`. **Lives at the clinical-notes seam, not inside the Cliniko HTTP layer** — its job is wiring those collaborators together so `ReviewViewModel` doesn't have to know about Cliniko. Don't relitigate the placement. |

---

## Common pitfalls

### PHI

- **Never** log `transcript`, prompt body, LLM response text, SOAP
  fields, patient name, DOB, or contact. `OSLog` `privacy: .public`
  is reserved for **structural** values: attempt counter, `String(describing:
  type(of: error))`, `SchemaError` case tags, dotted JSON `keyPath`s.
- **Never** interpolate caught `Error.localizedDescription` into a
  log line or fallback `reason` — `DecodingError`-style value-quoting
  is the classic leak. The processor uses two opaque sentinels:
  `reasonLLMError` and `reasonInvalidJSONAfterRetry`.
- See [`../../../.claude/references/phi-handling.md`](../../../.claude/references/phi-handling.md)
  for the full policy.

### `LLMProvider` is `Actor`-constrained

- Concrete providers (`MLXGemmaProvider`, `MockLLMProvider`) are
  actors. Actors cannot be subclassed, so test doubles must conform
  to `LLMProvider` directly. Use `MockLLMProvider` from
  `Tests/SpeechToTextTests/Utilities/MockLLMProvider.swift`.
- If you store `any LLMProvider` on an `@Observable` class, mark it
  `@ObservationIgnored` or you will hit the actor-existential crash.
  See [`../../../.claude/references/concurrency.md`](../../../.claude/references/concurrency.md) §1.

### Retry-once contract on `ClinicalNotesProcessor`

- First `generate` → if `validate(json:)` returns `.failure`, the
  processor builds a retry prompt that **quotes the bad response
  verbatim** and calls `generate` a second time.
- Quoting the bad response is load-bearing: with `temperature: 0` and
  a fixed `seed`, re-sending the original prompt would reproduce the
  same invalid output. The quote perturbs context enough for the
  model to attempt a correction.
- If the retry also fails schema validation, the processor returns
  `.rawTranscriptFallback(reason: reasonInvalidJSONAfterRetry)`. If
  either `generate` call **throws**, it returns
  `.rawTranscriptFallback(reason: reasonLLMError)`. The `process`
  method itself never throws — `ReviewScreen` always has something
  to render.

### `SessionStore` is session-only

- No `UserDefaults`, no on-disk persistence, no audit log of body
  content. Every mutator is a no-op when `active == nil`.
- `clear()` is called from: successful Cliniko export, app
  termination, user cancel, and `checkIdleTimeout()` crossing the
  injected threshold (default 30 min). The store does **not** own a
  timer — the app lifecycle drives `checkIdleTimeout()` so tests stay
  deterministic.
- The store is `@MainActor` so SwiftUI views observe `active` without
  actor hops. If you add an actor-typed dependency, it must be
  `@ObservationIgnored`.

### Determinism / golden tests

- `LLMOptions` defaults (`temperature: 0`, `topP: 1.0`, `seed: 42`),
  paired with the deterministic prompt builder, make `MLXGemmaProvider`
  output reproducible for a given transcript. The nightly LLM goldens
  (`RUN_MLX_GOLDEN=1`) depend on this. **Anything that breaks
  determinism breaks the goldens** — re-ordering the manipulations
  list, changing the prompt template's whitespace, varying option
  defaults per call site.
- Substitution order in `buildPrompt` is deliberate:
  `{{manipulations_list}}` first, `{{transcript}}` second. A
  transcript that literally contains a `{{…}}` marker must not
  re-trigger substitution.

### `ExportFlowCoordinator.shared`

- Singleton, configured once from `AppState.init`. **Don't construct
  ad-hoc**, and don't store its dependencies on the review VM.
  Tests swap fakes by re-calling `configure(...)`.
- `makeViewModel()` returns a fresh VM per Export tap; the previous
  one is dropped when the sheet dismisses. The FSM state is per-tap
  on purpose — don't cache.
- `isConfigured` gates the Export button so a misconfigured app
  fails closed rather than crashing on first tap.
- The `onSuccess` closure clears the `SessionStore` **before**
  closing the review window. Order matters — see the call-site
  comment.

### MLX provider

- The concrete `MLXGemmaProvider` ships in a follow-up PR against
  this same area. For its load / warmup / fallback story, see
  [`../../../.claude/references/mlx-lifecycle.md`](../../../.claude/references/mlx-lifecycle.md).

---

## Testing notes

Match the framework to the situation —
[`../../../.claude/references/testing-conventions.md`](../../../.claude/references/testing-conventions.md)
is the canonical reference. Highlights for this subdirectory:

- **Pure-logic + async tests** (`SessionStore`, `ClinicalNotesProcessor`,
  `ClinicalNotesPromptBuilder`, `ManipulationsRepository`): Swift
  Testing (`@Suite` / `@Test` / `#expect`); tag `.fast` via the
  suite. `SessionStoreTests` is a `@MainActor`-isolated suite because
  `SessionStore` is MainActor-isolated.
- **Use the fakes — never the real thing in CI:** `MockLLMProvider`
  for `LLMProvider`, `URLProtocolStub` for HTTP, `InMemorySecureStore`
  for Keychain.
- **`MockLLMProvider` modes** (see `Tests/SpeechToTextTests/Utilities/MockLLMProvider.swift`):
  - `.fixedResponse(String)` — every call returns the same string.
  - `.queuedResponses([String])` — pop-front; covers the retry-once
    flow (enqueue invalid then valid, assert `.success` and one
    retry).
  - `.error(any Error & Sendable)` — every call throws; covers the
    `.rawTranscriptFallback(reason: reasonLLMError)` path.
  - `setBehavior(_:)` swaps mid-test if a single test needs a more
    elaborate script.
  - `calls()` / `lastCall()` / `callCount()` for invocation
    assertions.
- **LLM golden tests** against the real `MLXGemmaProvider` are gated
  on `RUN_MLX_GOLDEN=1`, tagged `.slow` + `.requiresHardware`, and
  run nightly only — never in the default CI path.
- **Determinism in fixtures**: keep test transcripts and JSON
  payloads PHI-free (synthetic clinical wording is fine; no real
  patient names / DOBs).

---

## Related

- Topic-router refs:
  - [`../../../.claude/references/phi-handling.md`](../../../.claude/references/phi-handling.md) — never log PHI policy.
  - [`../../../.claude/references/mlx-lifecycle.md`](../../../.claude/references/mlx-lifecycle.md) — model load / warmup / fallback.
  - [`../../../.claude/references/concurrency.md`](../../../.claude/references/concurrency.md) — `@Observable` + actor existential, `Actor`-constrained protocols.
  - [`../../../.claude/references/testing-conventions.md`](../../../.claude/references/testing-conventions.md) — frameworks, tags, fakes.
- Sister `AGENTS.md`:
  - [`../Cliniko/AGENTS.md`](../Cliniko/AGENTS.md) — HTTP client, endpoints, audit store, exporter.
  - [`../../Views/ClinicalNotes/AGENTS.md`](../../Views/ClinicalNotes/AGENTS.md) — ReviewScreen, export flow UI, safety disclaimer.
- GitHub:
  - EPIC [#1 — Clinical Notes Mode](https://github.com/CloudbrokerAz/mac-speech-to-text/issues/1).
  - EPIC [#19 — Testing + Workflow Framework](https://github.com/CloudbrokerAz/mac-speech-to-text/issues/19).
  - Originating issues for files here: #2 (`SessionStore`), #3 (`LLMProvider`), #4 (`ClinicalNotesPromptBuilder`), #5 (`ClinicalNotesProcessor`), #6 (`ManipulationsRepository`), #14 (`ExportFlowCoordinator`).
