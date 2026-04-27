# Snapshot Tests

Image-snapshot regression tests for the two doctor-facing views where
visual regression is load-bearing:

- `ReviewScreen` (issue #13) — the SOAP edit + manipulations + excluded
  drawer surface.
- `SafetyDisclaimerView` (issue #12) — the one-time "drafting assistant,
  not a diagnostic tool" warning.

These tests were introduced in **issue #24 / F5** of EPIC #19 (Testing +
Workflow Framework). Snapshot coverage is **deliberately narrow** — see
[`.claude/references/testing-conventions.md`](../../../.claude/references/testing-conventions.md)
for the rationale (macOS font / Retina diffs are noisy; visual
regression only matters on the doctor-facing review surface).

## Files

```
Tests/SpeechToTextTests/Snapshots/
├── README.md                            # this file
├── SnapshotHost.swift                   # NSHostingView + appearance helper
├── SafetyDisclaimerSnapshotTests.swift  # 2 tests: light + dark
├── ReviewScreenSnapshotTests.swift      # 3 tests: empty / typical / overflow
└── __Snapshots__/
    ├── SafetyDisclaimerSnapshotTests/   # auto-named by the library
    │   ├── test_safetyDisclaimer_lightMode.1.png
    │   └── test_safetyDisclaimer_darkMode.1.png
    └── ReviewScreenSnapshotTests/
        ├── test_reviewScreen_empty.1.png
        ├── test_reviewScreen_typical.1.png
        └── test_reviewScreen_overflowYLong.1.png
```

## Render-host policy

PNG goldens are sensitive to the host macOS major version: font
hinting, Core Animation, and the system colour palette change between
macOS releases.

| Host | macOS | Runs snapshots? |
|---|---|---|
| Local dev machine | macOS 26 | ✅ goldens recorded here |
| Pre-push remote Mac (`scripts/remote-test.sh`) | macOS 26 | ✅ |
| GitHub Actions CI runner (`macos-15`) | macOS 15 | ❌ skipped by name |

Both `SafetyDisclaimerSnapshotTests` and `ReviewScreenSnapshotTests` are
in the `swift test --skip ...` list in `.github/workflows/ci.yml`,
alongside the other classes that need host-specific resources
(`AudioCaptureServiceTests`, `KeychainSecureStoreTests`, etc.). CI still
catches view-tree regressions via the existing ViewInspector
crash-detection tests in `Tests/SpeechToTextTests/Views/`. Snapshot
regressions are caught at pre-push.

If we ever bump CI to `macos-26` we can remove these classes from the
skip list and re-record on CI's runner.

## Running the tests locally

```bash
swift test --filter SafetyDisclaimerSnapshotTests
swift test --filter ReviewScreenSnapshotTests
```

A clean run prints `Test Suite ... passed` for each. A regression prints
the path of the diff PNG the library writes to a
`failures/` sibling of the golden so you can inspect it visually.

## Recording / re-recording goldens

Three ways to update goldens, in increasing order of risk:

1. **First-time capture (no golden exists yet).** The library
   automatically writes a new golden the first time a test runs without
   one and reports the test as failing with `"No reference was found
   on disk."`. Re-run the test — it now passes against the just-written
   golden. This is the recipe for landing a new snapshot test.

2. **Targeted re-record after an intentional UI change.** Set
   `withSnapshotTesting(record: .all) { ... }` around the specific
   `assertSnapshot` call (or, for an entire file, wrap each test in
   `withSnapshotTesting`). Run, inspect the new PNGs in the `git diff`
   carefully, then revert the `record:` argument before pushing.
   **Never** commit a test file with `record:` left as `.all` —
   that turns the test into a one-way overwrite.

3. **Bulk re-record (entire suite).** Set the `SNAPSHOT_TESTING_RECORD`
   environment variable:

   ```bash
   SNAPSHOT_TESTING_RECORD=all swift test --filter SafetyDisclaimerSnapshotTests
   SNAPSHOT_TESTING_RECORD=all swift test --filter ReviewScreenSnapshotTests
   ```

   Reserved for major UI overhauls. Diff the PNGs visually before
   committing — every changed pixel is a thing you must justify in
   review.

### Reviewer rules

- **Record-mode commits require a human reviewer.** A PR that touches
  `__Snapshots__/*.png` MUST include a written paragraph in the PR body
  describing the intentional visual change ("amber chip moved to the
  trailing edge of the header per design spec"), and ideally a
  before/after screenshot pair. A PR that only updates goldens with no
  written rationale is a regression-detection failure, not a feature.
- **Goldens are not generated artefacts** — they are versioned
  source-of-truth. Treat each PNG with the same scrutiny as a Swift
  file: review every diff, never let an automated tool overwrite them
  in CI, never auto-regenerate from production data.
- **No PHI.** Test fixtures in this directory use synthetic
  clinical-style filler. They never reference a real patient, chart, or
  transcript. See [`.claude/references/phi-handling.md`](../../../.claude/references/phi-handling.md).

## Why XCTest, not Swift Testing

`pointfreeco/swift-snapshot-testing` v1.19's public `assertSnapshot`
helper is XCTest-bound (it reads `XCTest`'s current-test machinery to
name the golden). Snapshot tests therefore stay on XCTest while
new pure-logic / async tests adopt Swift Testing. This matches the
hybrid story in
[`.claude/references/testing-conventions.md`](../../../.claude/references/testing-conventions.md):

| Kind | Framework |
|---|---|
| Snapshot | XCTest + swift-snapshot-testing |
| ViewInspector view-render / crash | XCTest + ViewInspector |
| Pure-logic / async | Swift Testing |
| XCUITest E2E | XCTest |
