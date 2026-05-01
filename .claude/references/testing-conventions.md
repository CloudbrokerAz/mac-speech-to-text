# Testing Conventions

> **Load this when:** adding or modifying tests, setting up a new test
> target, designing a mock, or deciding whether a new piece of code needs
> a unit test vs a view-render test vs a snapshot vs a UI test.

This reference consolidates the testing framework decisions made across
EPIC #19 (F1–F5).

---

## Layered strategy

| Layer | Where it runs | What it contains |
|---|---|---|
| `pre-commit` (L0) | Every commit, local | SwiftLint + gitleaks + whitespace/yaml/json/markdownlint. <5s. |
| `pre-push` (L1) | Remote Mac via SSH | Full `swift test` + UI suite. Hardware-dependent. |
| `GitHub Actions` (L2) | PR + `main` | `swift test --parallel --enable-code-coverage` skipping hardware-dependent classes; llvm-cov → lcov → Codecov; pre-commit scoped to PR diff. |
| Nightly (L3) | Scheduled, remote Mac | `RUN_MLX_GOLDEN=1` LLM goldens + full UI suite. |

`.github/workflows/ci.yml` is the source of truth.

---

## Which framework to reach for

| Kind of test | Framework |
|---|---|
| New pure-logic or async test | **Swift Testing** (`@Test` / `@Suite` / `#expect`) |
| SwiftUI view render / crash detection | **XCTest + ViewInspector** |
| XCUITest E2E | **XCTest** (no equivalent in Swift Testing) |
| Visual regression for ReviewScreen / SafetyDisclaimer | **`pointfreeco/swift-snapshot-testing`** (scoped — see "Snapshots" below) |

Existing XCTest files stay. New code voluntarily adopts Swift Testing.
`Tests/SpeechToTextTests/Utilities/SwiftTestingExemplarTests.swift` is the
canonical idiom reference.

---

## Tags

Every Swift Testing test carries at least one tag from
`Tests/SpeechToTextTests/Utilities/TestTags.swift`:

| Tag | Meaning |
|---|---|
| `.fast` | Pure-logic, sub-millisecond. Default for new code. |
| `.slow` | Noticeably slower (real I/O, large fixtures). Promote a `.fast` test only when it becomes relevant for nightly-only runs. |
| `.requiresHardware` | Needs real mic / Accessibility TCC / display server / user keychain. Skipped on CI runners. |

Apply with `@Test(.tags(.fast))` or propagate down from `@Suite(.tags(.fast))`.

XCTest classes cannot be tagged. CI still filters them by name (see next
section).

---

## Mocking patterns (already on main)

| Dependency | Test-only replacement | File |
|---|---|---|
| HTTP (`URLSession`) | `URLProtocolStub.install(_:)` returning a `URLSessionConfiguration` | `Tests/SpeechToTextTests/Utilities/URLProtocolStub.swift` |
| HTTP cross-suite serialisation | `URLProtocolStubGate.shared.withGate(_:)` (Swift Testing only) | `Tests/SpeechToTextTests/Utilities/URLProtocolStubGate.swift` |
| HTTP response fixtures | `HTTPStubFixture.load(_:)` / `loadJSON(_:,_:)` loading from `Tests/SpeechToTextTests/Fixtures/` | `Tests/SpeechToTextTests/Utilities/HTTPStubFixture.swift` |
| Keychain (`SecureStore`) | `InMemorySecureStore` — actor-isolated `[String: Data]`, never imports `Security` | `Tests/SpeechToTextTests/Utilities/InMemorySecureStore.swift` |
| LLM (`LLMProvider` — once #3 lands) | `MockLLMProvider` with canned prompt-hash → response lookup | pending #3 |

Real Keychain / real LLM inference are **never** exercised in CI. They
run locally or pre-push on a real Mac.

---

## URLProtocolStub process-wide gate

`URLProtocolStub` keeps a single global `currentResponder`. Swift
Testing's `.serialized` trait is **suite-local** — two Swift Testing
suites that both stub HTTP race across the suite boundary because the
scheduler still parallelises between suites. The race manifests as one
suite's `defer { reset() }` clobbering another suite's responder
mid-flight (PR #84 CI commit `964d877`: a Hugging Face 401 against
`ModelDownloaderTests.happyPathDownload`).

`URLProtocolStubGate` (issue #85) is the authoritative process-wide
serialisation point. Adoption rule:

- **Always** wrap a Swift Testing `@Test` body in
  `try await URLProtocolStubGate.shared.withGate { ... }` if it calls
  `URLProtocolStub.install(_:)` / `installScoped(_:)`.
- **Never** rely on `.serialized` alone for HTTP-stubbed Swift Testing
  suites. Suite-local serialisation does not protect against
  cross-suite races.
- XCTest test classes do **not** need to adopt the gate — XCTest
  scheduling has empirically coexisted with Swift Testing since #20
  without flakes. Mixing frameworks is fine; mixing Swift Testing
  suites is not (until both have the gate).

```swift
@Suite("My HTTP suite", .tags(.fast))
struct MyHTTPSuite {
    @Test func happyPath() async throws {
        try await URLProtocolStubGate.shared.withGate {
            let config = URLProtocolStub.install { request in
                // ...build response...
            }
            defer { URLProtocolStub.reset() }
            // ...exercise SUT...
        }
    }
}
```

The gate is non-reentrant and not cancellation-aware (test-only
utility). See `URLProtocolStubGate.swift` for the rationale.

Reference adopters:

- `Tests/SpeechToTextTests/Services/ModelDownloaderTests.swift`
- `Tests/SpeechToTextTests/Services/Cliniko/ClinikoStatusThreadingTests.swift`

**Known gap:**
`Tests/SpeechToTextTests/ViewModels/ExportFlowViewModelTests.swift` is
also a Swift Testing `@Suite` that installs `URLProtocolStub`, but it
is `@MainActor`-isolated and migrating it requires resolving the
`@MainActor` × `@Sendable` interaction across 22 test bodies. Tracked
as a follow-up to #85 — until the migration lands, the suite is
protected only by its `.serialized` trait and remains a cross-suite
race candidate against the gated suites above.

---

## Fixtures layout

```
Tests/SpeechToTextTests/Fixtures/
  cliniko/
    requests/<endpoint>.json         # expected outgoing payloads
    responses/<endpoint>.json        # canned responses for URLProtocolStub
  soap/
    valid/<case>.json                # valid SOAP JSON from the LLM
    invalid/<case>.json              # edge cases the schema guard must reject
  llm/
    prompts/<case>.txt
    expected/<case>.json             # goldens (only used when RUN_MLX_GOLDEN=1)
```

Fixtures are code. Changes ship in a PR that explains *why* the shape
changed. **Never auto-regenerate fixtures from production data** — they
must never contain PHI.

---

## Snapshot tests (narrow)

`pointfreeco/swift-snapshot-testing` v1.17+ landed in #24 / F5 and is
scoped deliberately to:

- `ReviewScreen` (SOAP editor + manipulations + excluded drawer — #13)
  — three states: empty, typical, overflow-y-long.
- `SafetyDisclaimerView` (#12) — light + dark mode.

Everything else gets ViewInspector crash tests, not image snapshots.
Rationale: macOS font rendering and Retina scaling make blanket snapshot
suites noisy; visual regression only matters on the doctor-facing
review surface.

Tests live under `Tests/SpeechToTextTests/Snapshots/` and use
`SnapshotHost.hosting(_:size:appearance:)` to mount the SwiftUI view in a
borderless offscreen `NSWindow` so SwiftUI's `.onAppear` lifecycle fires
deterministically (without a window mount, animations and onAppear-driven
state transitions are silently skipped). Goldens live in
`__Snapshots__/<TestClass>/`. See `Tests/SpeechToTextTests/Snapshots/README.md`
for the recording workflow + reviewer policy.

**Render-host policy.** PNG goldens are sensitive to host macOS
version (font hinting + Core Animation diffs). The CI runner is
`macos-15`; the dev / pre-push remote-Mac host is `macos-26`. Snapshot
test classes are therefore in CI's by-name skip list, alongside the
other hardware-dependent classes. CI keeps signal via the existing
ViewInspector crash tests for the same views; snapshot regressions
are caught at pre-push and locally.

**Record mode** (`SNAPSHOT_TESTING_RECORD=all`) requires a human
reviewer on the resulting PR. Any PR that touches `__Snapshots__/*.png`
must include a written rationale + before/after screenshots — a
goldens-only PR with no narrative is a regression-detection failure,
not a feature.

---

## CI skip list (current)

CI runs the XCTest suite minus these classes (hardware-dependent). When
an XCTest class migrates to Swift Testing and picks up
`.requiresHardware`, remove it from the list:

- `AudioCaptureServiceTests` — `AVAudioEngine.start` (real mic)
- `PermissionServiceTests` — `AXIsProcessTrustedWithOptions` / TCC
- `TextInsertionServiceTests` — `CGEventPost` + display server
- `VoiceTriggerMonitoringServiceTests` — transitively needs real mic
- `WakeWordServiceTests` — reads real WAV fixtures
- `GeneralSectionPersistenceTests` — shared-UserDefaults race under `--parallel` (fix tracked in #32)
- `SafetyDisclaimerSnapshotTests` — PNG goldens recorded on macOS-26; CI is macOS-15
- `ReviewScreenSnapshotTests` — same as above

The long-term target is to migrate these to Swift Testing + `.requiresHardware`
so the CI filter becomes `--skip-tag requiresHardware` (closes #31).

---

## Writing a new test — minimum bar

1. **Services**: a unit test. Hand-rolled protocol mocks in the test file.
2. **SwiftUI views**: a ViewInspector render / crash-detection test —
   even a one-line `XCTAssertNotNil(MyView())` is valuable because it
   catches `@Observable` + actor-existential regressions.
3. **New HTTP client**: tests via `URLProtocolStub` + fixtures under
   `Fixtures/cliniko/`.
4. **New credential-store consumer**: tests using `InMemorySecureStore`.
5. **LLM-consuming code**: tests via `MockLLMProvider` (unit) + goldens
   gated behind `RUN_MLX_GOLDEN=1` (nightly).

Every GH issue's acceptance-criteria section must name the tests the PR
is expected to add.

---

## Local workflow

```bash
swift test --parallel                                     # fast, most common
swift test --filter MyNewClassTests                       # while iterating
swift test --parallel --enable-code-coverage              # match CI shape
SWIFT_TEST_EXTRA="--skip-tag requiresHardware" ./scripts/remote-test.sh
pre-commit run --files <files>                            # mirror CI hooks
```

---

## Related files

- `.github/workflows/ci.yml` — CI definition.
- `Tests/SpeechToTextTests/Utilities/` — test helpers + exemplars.
- `.pre-commit-config.yaml` — local hook definitions.
