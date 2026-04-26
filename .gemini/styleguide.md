# Gemini Code Assist — styleguide

> Read `AGENTS.md` at the project root (and `.claude/references/*.md`)
> before reviewing a PR in this repo. Those documents are the authoritative
> rules; this file is a reviewer-oriented summary that calibrates
> Gemini's output to match the project's conventions.

## Project at a glance

A privacy-focused local-first macOS speech-to-text menu-bar app, being
extended into a clinical documentation assistant for chiropractors.
Swift 5.9 language mode / Swift 6.2 compiler. macOS 14+ baseline, macOS
26 for development. Swift Package Manager. SwiftLint `--strict` + two
custom concurrency rules. FluidAudio (Parakeet v3) for ASR; MLX Swift +
Gemma 4 E4B-IT (first-run download) for the clinical-notes LLM; URLSession actor for
Cliniko API. **No cloud services** — only egress is the doctor-initiated
`POST /treatment_notes` to their own Cliniko tenant over TLS.

---

## What to prioritise in every review

### Security & PHI (highest priority — block on violations)

- **PHI must never appear in logs, crash-report messages, UserDefaults,
  on-disk caches, or external tooling.** PHI in this project means:
  consultation transcripts, generated SOAP notes, suggested
  manipulations, excluded-content snippets, patient demographics, and
  `treatment_note` bodies.
- `OSLog` / `Logger` calls: any non-structural interpolation of PHI is a
  blocker. `privacy: .public` is reserved for structural values only
  (HTTP status, error-case name, path template, method). Everything
  else must be `privacy: .private`.
- `fatalError` / `preconditionFailure` / `assertionFailure` messages:
  **never** interpolate PHI. These show up in crash reports.
- Secrets, API keys, `.env` files, entitlements with hardcoded team
  IDs, GitHub PATs — never. Cliniko API keys live in Keychain via the
  `SecureStore` protocol with
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
- `AuditStore` entries must carry metadata only: timestamp, patient_id
  (opaque string), appointment_id, note_id (from Cliniko response),
  HTTP status, app version. **Never** request/response body,
  transcript, or patient name.
- Test fixtures must use obviously-synthetic data (`@example.test`
  domains, placeholder IDs). Flag any fixture that looks like copied
  production data.

### Concurrency correctness (block on violations)

- Any `any SomeActorProtocol` / any actor-existential field on an
  `@Observable` class **must** be marked `@ObservationIgnored`.
  Omitting this causes an ARM64 pointer-authentication crash on first
  Observation scan. SwiftLint rule
  `observable_actor_existential_warning` catches most cases — flag any
  usage the rule may have missed.
- Core Audio / Carbon / `DispatchSource` callbacks must run through a
  `nonisolated` entry and hop to `@MainActor` via
  `Task { @MainActor … }` for state mutation. Never call a `@MainActor`
  method directly from an audio-thread callback.
- `nonisolated(unsafe)` is tolerated only for: (a) `deinit` cleanup,
  (b) audio/system callbacks with a self-synchronised data type,
  (c) internally thread-safe value types. Flag every other usage for
  justification — the custom SwiftLint rule
  `nonisolated_unsafe_warning` surfaces them.
- Actors cannot be subclassed, so mocks must go through an
  `Actor`-constrained protocol. Flag any mock-by-subclass on an actor.
- Every new `@Observable` view model requires a ViewInspector render /
  crash-detection test. Flag PRs that add a view model without one.

### Code quality

- **No** force-unwraps (`!`) without a justifying comment and a `guard`
  above them. Flag every `!`.
- **No** `try!` outside test code. `try?` is only legitimate where
  `nil` is a genuine "absent" signal, not to swallow errors.
- **No** `@ObservedObject` / `@StateObject` / `ObservableObject` — this
  project is on the `@Observable` macro. Flag any legacy
  ObservableObject usage.
- Prefer `let` unless mutation is required.
- No emoji in source or test fixtures unless the user has asked for
  them.
- No "nice-to-have" comments that just restate the code. Comments
  should explain *why*, not *what*. Flag large docstring blocks that
  paraphrase the implementation.

### Testing

- New pure-logic and async tests go in **Swift Testing**
  (`@Test` / `@Suite` / `#expect`), tagged with `.fast` / `.slow` /
  `.requiresHardware` from
  `Tests/SpeechToTextTests/Utilities/TestTags.swift`. The canonical
  idiom lives in `SwiftTestingExemplarTests.swift`.
- UI / ViewInspector / XCUITest stay on **XCTest**.
- Snapshot tests (`pointfreeco/swift-snapshot-testing`) are scoped to
  `ReviewScreen` + `SafetyDisclaimerView` only. Don't encourage broader
  snapshot coverage.
- **Never** encourage a test that hits real Keychain / real Cliniko /
  real LLM inference in the default CI path. Use `InMemorySecureStore`
  / `URLProtocolStub` + fixtures / `MockLLMProvider`. Golden-file LLM
  tests are gated behind `RUN_MLX_GOLDEN=1` (nightly only).
- Every service that touches PHI needs an invariant test asserting it
  doesn't leak (e.g. snapshot `UserDefaults.standard.dictionaryRepresentation()`
  before/after a lifecycle).

### Workflow hygiene

- `pre-commit run --all-files` is assumed to be green before push.
  SwiftLint strict + gitleaks are mandatory hooks. Flag any PR that
  looks like it was pushed without them.
- Every GH issue closes via `Closes #N` in the PR body.
- PRs should carry three issue-level checkpoint comments (start / PR
  opened / merged) — absence is a process smell but not a code smell;
  flag only in the PR summary, not as inline comments.

### Locked technical decisions — do not re-litigate

The following are intentional and live in the EPIC + `.claude/CLAUDE.md`:

| Area | Decision |
|---|---|
| LLM runtime | MLX Swift in-process (no XPC / daemon) |
| LLM model v2 | Gemma 4 E4B-IT (MLX 4-bit) via `mlx-swift-lm` 3.31.3's native `gemma4` registry; supersedes v1 Gemma 3 4B-IT (#18 cutover) |
| Model delivery | First-run download with sha256-manifest verification into `~/Library/Application Support/<bundle>/Models/<model-dir>/` (DMG ~50 MB; weights opt-in). See `.claude/references/mlx-lifecycle.md`. |
| Persistence | Session-only, cleared on export/quit — no on-disk PHI |
| Cliniko | API integration in v1, direct from doctor's Mac to doctor's tenant |
| UI entry | Settings toggle + "Generate Notes" action after recording |
| Review layout | Two-column (SOAP editor / Manipulations + Excluded drawer) — wireframe in issue #13 |
| Safety | One-time "not a diagnostic tool" disclaimer, UserDefaults ack (#12) |
| Test frameworks | Swift Testing (new) + XCTest (UI / ViewInspector) |
| HTTP mocking | Hand-rolled `URLProtocolStub` (zero deps) |
| Keychain mocking | `SecureStore` protocol + `InMemorySecureStore` actor fake |

**Do not suggest:** switching to a different LLM runtime, adding cloud
telemetry, shipping via the Mac App Store, persisting PHI, introducing a
third-party HTTP mocking library, or replacing SwiftLint with a
different linter. These have been evaluated and rejected.

---

## PR summary style

When summarising a PR, lead with the behavioural change in one sentence,
then call out PHI / concurrency risks (if any) and the test coverage
delta (what was added, what's intentionally deferred). Keep it to ~150
words. Reviewers here are time-pressed.

## When to stay quiet

- Style nits already enforced by SwiftLint `--strict` or by pre-commit
  hooks (trailing whitespace, import ordering, closure spacing).
  Comment only if the hook is somehow bypassed.
- Test-coverage "should also test X" comments when the PR explicitly
  defers X to a tracked issue. Cross-check the PR body and linked
  issues before suggesting new tests.
- Refactors / abstractions that aren't justified by the PR's scope.
  The project prefers "three similar lines over a premature
  abstraction."
