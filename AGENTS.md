# AGENTS.md — Swift macOS App + Clinical Notes Mode

A privacy-focused local-first menu-bar speech-to-text app for macOS, in
the middle of being extended into a clinical documentation assistant
for chiropractors. Swift 5.9 language mode, Swift 6.2 compiler, macOS
14+ baseline (development on macOS 26). FluidAudio SDK wrapping
Parakeet v3 for transcription; MLX Swift + Gemma 4 E4B-IT (in-process,
bundled) for the clinical-notes LLM layer. No cloud services at any
point — all processing is on-device, and the only egress is the
doctor-initiated Cliniko API POST from their Mac to their Cliniko
tenant.

Work is tracked as GitHub issues in this repo. Two parallel EPICs:

- **[#19 — Testing + Workflow Framework](https://github.com/CloudbrokerAz/mac-speech-to-text/issues/19)** (children #20–#25). Lands first.
- **[#1 — Clinical Notes Mode](https://github.com/CloudbrokerAz/mac-speech-to-text/issues/1)** (children #2–#18). Rides on top of #19.

---

## Topic Router

Load the reference file that matches the task. **Do not load all of
them at once** — the whole point of the router is context efficiency.

| If you are… | Load |
|---|---|
| Writing a new `@Observable` class, actor, or touching `@MainActor` / `nonisolated(unsafe)` | [`.claude/references/concurrency.md`](.claude/references/concurrency.md) |
| Adding or modifying tests (unit, ViewInspector, snapshot, fixtures, tags) | [`.claude/references/testing-conventions.md`](.claude/references/testing-conventions.md) |
| Building or debugging the Cliniko HTTP client, endpoints, retries, errors | [`.claude/references/cliniko-api.md`](.claude/references/cliniko-api.md) |
| Touching anything that sees transcripts, notes, patient data, or writes logs | [`.claude/references/phi-handling.md`](.claude/references/phi-handling.md) |
| Working on the LLM provider, model loading / warmup / fallback | [`.claude/references/mlx-lifecycle.md`](.claude/references/mlx-lifecycle.md) |
| Touching the menu-bar icon, hotkey, recording modal window, or Accessibility text insertion | [`.claude/references/menubar-integration.md`](.claude/references/menubar-integration.md) |

Component-scoped `AGENTS.md` files live alongside the
clinical-notes-mode subdirectories. Load the one whose folder you're
editing in:

- [`Sources/Services/ClinicalNotes/AGENTS.md`](Sources/Services/ClinicalNotes/AGENTS.md)
  — `SessionStore`, `ClinicalNotesProcessor`, `ClinicalNotesPromptBuilder`,
  `LLMProvider`, `ManipulationsRepository`, `ExportFlowCoordinator`.
- [`Sources/Services/Cliniko/AGENTS.md`](Sources/Services/Cliniko/AGENTS.md)
  — `ClinikoClient`, `ClinikoEndpoint`, `ClinikoError`,
  `ClinikoCredentialStore`, `ClinikoShard`, `ClinikoAuthProbe`,
  `ClinikoPatientService`, `ClinikoAppointmentService`,
  `TreatmentNoteExporter`, `AuditStore`.
- [`Sources/Views/ClinicalNotes/AGENTS.md`](Sources/Views/ClinicalNotes/AGENTS.md)
  — `SafetyDisclaimerView`, `ReviewScreen` / `ReviewWindow` /
  `ReviewWindowController` / `ReviewViewModel`, `SOAPSectionEditor`,
  `ManipulationsChecklist`, `ExcludedContentDrawer`, `RawTranscriptSheet`,
  `PatientPickerView` / `PatientPickerViewModel`, `ExportFlowView` /
  `ExportFlowViewModel`.

---

## Correctness Checklist

Every item here is **always / never**. No "consider" bullets — those
belong in PR review, not in the hard-rules file.

### Concurrency

- **Always** mark `any SomeActorProtocol` / any actor existential on an
  `@Observable` class with `@ObservationIgnored`.
- **Always** run Core Audio / Carbon / `DispatchSource` callbacks from
  a `nonisolated` entry, hopping to `@MainActor` via `Task` for any
  state mutation.
- **Never** call a `@MainActor` method directly from an audio-thread
  callback.
- **Always** use `Actor`-constrained protocols for mockability; actors
  cannot be subclassed.
- **Always** pair every new `@Observable` view model with a
  ViewInspector render-crash test.

### Security / PHI

- **Never** log transcript content, SOAP-note body, patient name /
  DOB / contact, or raw Cliniko responses. `OSLog` `privacy: .public`
  is reserved for structural values only (status, method, path
  template, error-case name).
- **Never** interpolate PHI into `fatalError` / `assertionFailure` /
  `preconditionFailure` messages.
- **Never** commit secrets, API keys, `.env` files, or entitlements
  with hardcoded team IDs.
- **Never** paste a GitHub PAT, API key, or password into chat — the
  existing `gh auth status` token is the only one we use. If a user
  pastes one anyway, warn and refuse.
- **Always** store Cliniko API keys in Keychain (`SecureStore` protocol)
  with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
- **Always** verify `AuditStore` entries carry metadata only (timestamp,
  patient_id, appointment_id, note_id, status, app_version) — never
  body.

### Code quality

- **Never** force-unwrap (`!`) without a justifying comment and a
  guard above it.
- **Never** use `try!` outside test code. `try?` only where a `nil` is
  a legitimate "missing" signal, not to swallow errors.
- **Never** use `@ObservedObject` / `@StateObject` / `ObservableObject`
  — this project is on the `@Observable` macro.
- **Always** use `let` unless mutation is genuinely needed.
- **Always** respect SwiftLint `--strict`. The custom rules
  `observable_actor_existential_warning` and
  `nonisolated_unsafe_warning` are surface the patterns in
  [`concurrency.md`](.claude/references/concurrency.md).
- **Always** run `pre-commit run --all-files` before a PR (or let CI
  do it — it runs diff-scoped hooks on every PR).

### Testing

- **Always** add tests with new code — see
  [`testing-conventions.md`](.claude/references/testing-conventions.md)
  for which framework fits which situation.
- **Always** tag new Swift Testing tests with `.fast` / `.slow` /
  `.requiresHardware` (from `Tests/SpeechToTextTests/Utilities/TestTags.swift`).
- **Never** add a test that hits the real Keychain, real Cliniko, or
  runs a real LLM inference in the default CI path — use the
  `InMemorySecureStore` / `URLProtocolStub` / `MockLLMProvider` fakes.
  Gated-by-env-var golden tests are allowed and run in nightly only.

### Workflow

- **Always** comment on the GitHub issue at three checkpoints:
  (a) starting — plan + branch name, (b) PR opened — link + "awaiting CI",
  (c) merged — PR link + merge commit SHA + one-line summary.
- **Always** post an "unblocked by" comment on downstream issues when
  their blocker merges.
- **Always** manually tick EPIC task-list checkboxes when a child
  merges — GitHub does not auto-tick our format.
- **Always** verify the post-merge `main` CI run
  (`gh run list --branch main --limit 3`) before declaring a merge-batch
  done.
- **Never** re-litigate locked technical decisions (LLM runtime, model
  version v1, persistence strategy, UI entry point, Cliniko scope,
  testing stack) without an explicit user ask — they live in the
  EPIC body and `.claude/CLAUDE.md`.

### Subagents & code review

- **Always** pass `model: "opus"` explicitly when calling the `Agent`
  tool. The parent session is Opus; several subagent definitions default
  to Sonnet and will silently downgrade if you omit the override. This
  applies to every `Agent` invocation — `Explore`, `general-purpose`,
  and every `pr-review-toolkit:*` reviewer.
- **Always** run the three-layer review pipeline on a non-trivial PR:
  1. **Pre-PR (local):** spawn a `pr-review-toolkit:code-reviewer`
     subagent with `model: "opus"` over the diff before you push, and
     apply/fold in its blockers. For PHI-sensitive or concurrency-heavy
     changes also spawn `pr-review-toolkit:silent-failure-hunter` and
     (for new types) `pr-review-toolkit:type-design-analyzer` in
     parallel.
  2. **Automated (on PR open):** Gemini Code Assist runs automatically
     via the GitHub App (see `.gemini/config.yaml` +
     `.gemini/styleguide.md`). Its summary + inline comments are
     treated as peer review; address them before merging. Re-trigger
     with a `/gemini review` comment if the PR materially changed.
  3. **On-demand deep dive:** invoke the `/code-review` skill
     (`code-review:code-review`) when the PR is large, touches
     multiple subsystems, or has review comments that need triage.
     Prefer it over re-running the subagent because it operates on the
     PR surface (including comments) rather than the local diff.
- **Never** skip the pre-PR subagent pass on substantive changes. A
  `wc -l` >~30 on the diff, or anything touching PHI / concurrency /
  HTTP / Keychain, is substantive.

---

## Tech stack quick reference

| Layer | Technology |
|---|---|
| Language | Swift 5.9 (tools) / 6.2 (compiler) |
| UI | SwiftUI with `@Observable` |
| System | AppKit (menu bar, hotkey, Accessibility) |
| Audio | AVFoundation, 16 kHz mono |
| ASR | FluidAudio → Parakeet v3 |
| LLM (clinical notes) | MLX Swift + Gemma 4 E4B-IT (4-bit, first-run download) |
| HTTP | URLSession in an actor (Cliniko) |
| Credentials | Keychain via `SecureStore` protocol |
| Testing | XCTest + ViewInspector + Swift Testing + `pointfreeco/swift-snapshot-testing` (scoped) |
| Lint | SwiftLint strict + 2 custom concurrency rules |
| Build | Swift Package Manager |
| CI | GitHub Actions (macOS-15 runner) |

---

## Common commands

```bash
# Build
swift package resolve
swift build                                    # debug
swift build -c release

# Test
swift test --parallel                          # fast, most common
swift test --filter SomeTests                  # iterate
swift test --parallel --enable-code-coverage   # match CI shape
./scripts/remote-test.sh                       # remote Mac via SSH
SWIFT_TEST_EXTRA="--skip-tag requiresHardware" ./scripts/remote-test.sh

# Quality
swiftlint lint --strict
pre-commit run --all-files
pre-commit run --files <specific-file>         # scoped

# App bundle (needed for UI tests)
./scripts/build-app.sh
./scripts/build-app.sh --sync                  # rsync to remote Mac
./scripts/run-ui-tests.sh

# LLM hardware-eval (golden tests, gated on RUN_MLX_GOLDEN=1)
./scripts/llm-prefetch.sh                      # populate model dir from manifest
./scripts/llm-eval.sh                          # prefetch + run golden tests + RSS
./scripts/llm-reset.sh --dry-run               # inspect what would be wiped
./scripts/llm-reset.sh --yes                   # clean re-download for first-run UX

# GitHub
gh issue list --state open --label epic
gh issue view <N> --comments
gh pr checks <N> --watch --fail-fast
gh run list --branch main --limit 3            # verify post-merge CI
```

---

## Project structure (abbreviated)

```
Sources/
  SpeechToTextApp/   # @main, AppDelegate, AppState
  Services/          # Business logic (actors + @MainActor classes)
  Models/            # Data structures
  Views/             # SwiftUI views + ViewModels
  Utilities/         # Extensions, Constants

Tests/SpeechToTextTests/
  Utilities/         # URLProtocolStub, InMemorySecureStore, TestTags, exemplars
  Fixtures/          # cliniko/, soap/, llm/ — test bundle resources
  Services/          # service unit tests
  Views/             # ViewInspector + crash-detection

UITests/             # XCUITest (pre-push / remote Mac only)

.claude/references/  # Topic router loads these on demand
docs/                # Long-form docs (also linked from references/)
scripts/             # build, test, deploy automation
```

---

## Clinical Notes Mode (flow overview)

The post-recording extension. From a completed transcript, produce a
draft SOAP note, let the doctor edit it, and POST to Cliniko — all
on-device, session-only PHI, opt-in via Settings.

1. **Settings toggle** flips Clinical Notes Mode on (`AppState`
   wires the dependencies — see `Sources/SpeechToTextApp/AppState.swift`).
   Once on + Cliniko credentials present, Settings → Clinical Notes
   exposes a **dedicated "Recording shortcut"** row (`#91`) bound to
   `KeyboardShortcuts.Name.clinicalNotesRecord` (unbound by default),
   and the menu bar grows a **"Start Clinical Note"** item (`#92`) as
   the discoverability sibling. The default
   `holdToRecord` / `toggleRecording` chord stays pure STT for general
   dictation; the new chord and menu item are the only production
   triggers for the clinical pipeline — both gates flip the shortcut
   off (`KeyboardShortcuts.disable(.clinicalNotesRecord)`) and hide
   the menu item (`MenuBarViewModel.canStartClinicalNote` returns
   false) so neither surface fires when prerequisites are missing.
2. **Recording** runs unchanged (FluidAudio → `RecordingSession`).
   General dictation uses the existing chord. Clinical sessions use
   `clinicalNotesRecord` or the "Start Clinical Note" menu item →
   `LiquidGlassRecordingModal` (auto-starts recording on present via
   the modal's existing `.task(id:)`).
3. **Generate Notes** action on the recording modal hands the transcript to
   `SessionStore` → `ClinicalNotesProcessor` → `LLMProvider`
   (`MLXGemmaProvider` / `MockLLMProvider`). Retry-once on schema-invalid
   JSON, raw-transcript fallback on second failure.
4. **Safety Disclaimer** modal shows on first entry (one-time
   `UserDefaults` ack — issue [#12](https://github.com/CloudbrokerAz/mac-speech-to-text/issues/12)).
5. **ReviewScreen** opens with two-column layout (SOAP editors +
   manipulations checklist + excluded drawer — issue [#13](https://github.com/CloudbrokerAz/mac-speech-to-text/issues/13)).
6. **PatientPicker** sheet selects a Cliniko patient + appointment via
   `ClinikoPatientService` / `ClinikoAppointmentService`.
7. **Export** runs `ExportFlowCoordinator` → `TreatmentNoteExporter` →
   `POST /treatment_notes` → metadata-only `AuditStore` row → success
   surface clears `SessionStore`.

Component AGENTS.md (load the one whose folder you're editing):

- [`Sources/Services/ClinicalNotes/AGENTS.md`](Sources/Services/ClinicalNotes/AGENTS.md)
  — pipeline services + LLM seam.
- [`Sources/Services/Cliniko/AGENTS.md`](Sources/Services/Cliniko/AGENTS.md)
  — HTTP client + credentials + audit ledger.
- [`Sources/Views/ClinicalNotes/AGENTS.md`](Sources/Views/ClinicalNotes/AGENTS.md)
  — Review / Picker / Export UI.

EPIC: [#1 — Clinical Notes Mode](https://github.com/CloudbrokerAz/mac-speech-to-text/issues/1).
Locked technical decisions (LLM runtime, model v1, persistence, UI entry,
Cliniko scope, testing stack) live in the EPIC body and
`.claude/CLAUDE.md` — don't re-litigate without an explicit ask.

---

## Warm Minimalism (design aesthetic)

Frosted glass modals (`.ultraThinMaterial`), amber palette
(`AmberLight` / `AmberPrimary` / `AmberBright` in
`Utilities/Extensions/Color+Theme.swift`), spring animations
(`response: 0.5, dampingFraction: 0.7`), floating window level for
modals, minimal chrome, content-focused. All new UI adheres.
