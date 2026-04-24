# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**Project Type**: macOS native application for local speech-to-text capture
**Language**: Swift 6.x (compiler) with Swift 5.9 language mode (Package.swift)
**Platform**: macOS 14+ (minimum), macOS 26+ (development)

## Current initiative (last updated 2026-04-24)

**Clinical Notes Mode** — extend this app into a local-first clinical documentation assistant for chiropractors. Record consultation → local LLM (MLX Swift + Gemma 3 4B-IT v1; Gemma 4 E4B migration gated on ml-explore/mlx-swift#389) → structured SOAP notes → doctor review → Cliniko API export. 100% on-device. Session-only PHI. No cloud.

**Work is tracked as GitHub issues** in `CloudbrokerAz/mac-speech-to-text`. Always start a session by reading the open EPICs + any assigned issues:

```bash
gh issue list -R CloudbrokerAz/mac-speech-to-text --state open --label epic
gh issue view <N> --comments   # for any specific issue you pick up
```

**Two parallel EPICs**:
- **#19 — Testing + Workflow Framework** (children #20–#25). Must land first; unblocks feature work. Order: F1 → (F2, F3 parallel) → F4 → F6 → F5.
- **#1 — Clinical Notes Mode** (children #2–#18). Rides on top of #19 outputs.

### Operating rules (binding)

1. **Use multiple Opus subagents liberally.** For any research/exploration spanning more than a couple of files, spawn parallel `Explore` / `general-purpose` agents. Keep the main thread for decisions and orchestration. Review-type agents (`pr-review-toolkit:code-reviewer`) run after substantive changes.
2. **Test everything.** Every new service gets a unit test; every new SwiftUI view gets a ViewInspector crash test; ReviewScreen + SafetyDisclaimer get snapshot tests. New pure-logic/async tests use **Swift Testing** (`@Test` / `#expect`) — see `Tests/SpeechToTextTests/Utilities/SwiftTestingExemplarTests.swift` for the canonical idiom. UI + ViewInspector stay on **XCTest**. Tag Swift Testing tests with `.fast` / `.slow` / `.requiresHardware` from `Tests/SpeechToTextTests/Utilities/TestTags.swift`; CI filters via `--skip-tag requiresHardware` where applicable. Acceptance criteria in every GH issue call out the test expectations.
3. **Talk to the tickets.** Three comment checkpoints per issue: (a) starting — plan + branch name, (b) PR opened — link + "awaiting CI", (c) **merged** — PR link + merge commit SHA + one-line summary. Link PRs with `Closes #N` so GitHub auto-closes. Also post an "unblocked by" comment on any downstream issue when its blocker merges. **Tick EPIC task-list checkboxes manually** when the child merges — GitHub only auto-ticks entries formatted as a bare `- [ ] #N`, which our EPICs usually aren't. **Always verify the post-merge main-branch workflow run** (`gh run list --branch main --limit 3`) before declaring a merge-batch done — the PR's CI and main's CI are separate runs. Keep discussion in GitHub, not in chat.
4. **Point to docs, don't duplicate.** In PRs, issue comments, and subagent prompts, reference `AGENTS.md` (and, once #25 lands, `.claude/references/*.md` — a topic-router split) instead of restating context inline.
5. **Security.** Never echo or reuse a GitHub PAT pasted in chat — `gh auth status` already has a valid token. Cliniko API keys live in Keychain only (#22 / #7); never logged, never in UserDefaults. PHI is in-memory only, plus the HTTPS body at the moment of POST to Cliniko — nowhere else (no logs, crash reports, audit files, or external tooling).
6. **Respect pre-commit.** `pre-commit run --all-files` must pass; SwiftLint is strict; gitleaks is on. The custom rules `observable_actor_existential_warning` and `nonisolated_unsafe_warning` stay honoured.
7. **Don't re-litigate locked decisions** (see below) without an explicit user ask.

### Locked technical decisions (2026-04-24)

| Area | Decision |
|---|---|
| LLM runtime | MLX Swift in-process (ml-explore/mlx-swift-examples) |
| LLM model v1 | Gemma 3 4B-IT (MLX 4-bit); swap to Gemma 4 E4B when mlx-swift#389 lands (#18) |
| Model delivery | Bundled in the .app (DMG distribution, not App Store) |
| Persistence | Session-only, cleared on export/quit — no on-disk PHI |
| Cliniko | API integration in v1, mirror patterns from [CloudbrokerAz/epc-letter-generation](https://github.com/CloudbrokerAz/epc-letter-generation/tree/main/Sources/Services) |
| Manipulations | Placeholder JSON v1 (#6); user supplies real Cliniko taxonomy later |
| UI entry | Settings toggle + "Generate Notes" action after recording |
| Review layout | Two-column (SOAP editor left, Manipulations + Excluded drawer right) — wireframe embedded in #13 |
| Safety | One-time "not a diagnostic tool" disclaimer, UserDefaults ack (#12) |
| Test frameworks | Mixed: Swift Testing (new) + XCTest (UI + ViewInspector) |
| HTTP mocking | Hand-rolled Sendable `URLProtocolStub` (#21) — zero deps |
| Keychain mocking | `SecureStore` protocol + `InMemorySecureStore` actor fake (#22) |
| LLM mocking | `MockLLMProvider` fast path; `RUN_MLX_GOLDEN=1` gated goldens nightly |
| Snapshot testing | `pointfreeco/swift-snapshot-testing` v1.17+ — scoped to ReviewScreen + Disclaimer only |
| Coverage | slather → `codecov-action@v5` on PR (#20) |
| CI gains (#20) | `swift test --parallel -enableCodeCoverage` + pre-commit/action; UI + hardware-dependent tests skipped in CI, run pre-push on remote Mac |

### Watch-list / blockers

- **ml-explore/mlx-swift#389** — Gemma 4 E4B architecture support. Migration tracked in #18.
- **Real Cliniko manipulations taxonomy** — user-supplied; placeholder in #6 for now.
- **Disclaimer copy legal review** — draft in #12; must be reviewed before ship.

### Reference projects

- FluidAudio SDK: https://github.com/FluidInference/FluidAudio
- Cliniko API: https://docs.api.cliniko.com/
- Cliniko integration reference: https://github.com/CloudbrokerAz/epc-letter-generation/tree/main/Sources/Services
- avdlee/swiftui-agent-skill (Topic Router pattern source): https://github.com/avdlee/swiftui-agent-skill

## Primary Reference

Please see the root `./AGENTS.md` in this same directory for the main project documentation and guidance.

@/workspace/AGENTS.md

## Additional Component-Specific Guidance

For detailed module-specific implementation guides, also check for AGENTS.md files in subdirectories throughout the project.

These component-specific AGENTS.md files contain targeted guidance for working with those particular areas of the codebase.

## Important: Use Subagents Liberally

When performing any research, concurrent subagents can be used for performance and isolation.
Use parallel tool calls and tasks where possible.

## Quick Reference: Project Structure

```
Sources/
├── SpeechToTextApp/     # App entry point (@main, AppDelegate, AppState)
├── Services/            # Business logic layer (7 services)
├── Models/              # Data structures (5 models)
├── Views/               # SwiftUI views + ViewModels (12 files)
│   └── Components/      # Reusable UI components (4 files)
└── Utilities/           # Extensions, constants, and logging
    └── Extensions/      # Color+Theme, etc.

Tests/
└── SpeechToTextTests/   # XCTest suite (24 test files)

UITests/                 # XCUITest E2E tests

scripts/                 # Build and test automation
├── build-app.sh         # Build signed .app bundle (--sync for remote Mac)
├── smoke-test.sh        # Quick crash detection test
├── run-ui-tests.sh      # Run XCUITest suite
├── remote-test.sh       # Run tests on remote Mac via SSH
├── setup-signing.sh     # Configure code signing
├── export-dmg.sh        # Create distributable DMG
└── setup-ssh-for-mac.sh # Configure SSH for remote testing
```

## Key Architectural Patterns

1. **Service Layer Architecture**: All business logic in dedicated service classes
2. **@Observable State Management**: Modern Swift Observation framework (not @StateObject)
3. **Actor-Based Concurrency**: Thread-safe access to ML models and audio buffers
4. **Protocol-Based Testing**: Services use protocols for mockability
5. **Hybrid UI**: SwiftUI for views + AppKit for system integration (menu bar, hotkeys, accessibility)

## Development Workflow

### Building
```bash
swift package resolve      # Resolve dependencies
swift build               # Build from command line
# OR open in Xcode 26.x
```

### Testing
```bash
swift test                # Run all tests
swift test --parallel     # Run tests in parallel (faster)
./scripts/smoke-test.sh   # Run local smoke test (macOS only)
./scripts/run-ui-tests.sh # Run XCUITest E2E tests (macOS only)
# OR use Xcode Test Navigator (Cmd+6)
```

### Code Quality
```bash
swiftlint                 # Run linter
pre-commit run --all-files # Run all pre-commit hooks
```

## Swift Version & Features in Use

- **Compiler**: Swift 6.2.3 (Xcode 26.2)
- **Language Mode**: Swift 5.9 (`swift-tools-version: 5.9` in Package.swift)
- **Note**: Swift 6 strict concurrency warnings appear but are not errors due to 5.9 language mode

### Concurrency Features
- **async/await** for all asynchronous operations
- **Swift actors** for thread-safe concurrency (FluidAudioService, StreamingAudioBuffer)
- **@Observable macro** for reactive state management
- **@MainActor** for UI-bound classes
- **Sendable** conformance for thread-safe data types
- **Structured concurrency** with Task and async let
- **Task.detached** for breaking actor context inheritance

## CRITICAL: Build & Signing for UI Tests

**IMPORTANT**: Use `./scripts/build-app.sh` to create a signed .app bundle for UI tests. Do NOT use `swift build` alone - it creates a command-line tool, not an app bundle.

### Bundle ID and Permission State Issue

When the app is rebuilt with different code signing or bundle identifiers, macOS permission grants (microphone, accessibility) become invalid. The app must:

1. **Detect Bundle ID Changes**: Store and compare the current bundle identifier
2. **Reset Permission State**: When bundle ID changes, reset permission-related settings/state
3. **Re-prompt for Permissions**: Guide user through permission grant flow again

This is critical for development workflows where signing identities change between builds.

```bash
# Build signed .app bundle (required for UI tests)
./scripts/build-app.sh

# Build with rsync to remote Mac
./scripts/build-app.sh --sync

# Run UI tests
./scripts/run-ui-tests.sh
```

## Common Commands

```bash
# Development
open Package.swift           # Open in Xcode (generates Xcode project)
swift build                  # Build from command line (NOT for UI tests)

# Testing
swift test --parallel        # Run tests in parallel

# Code Quality
swiftlint lint --strict      # Lint with zero tolerance
swiftlint autocorrect        # Auto-fix violations

# Git Hooks
pre-commit install           # Install git hooks
pre-commit run --all-files   # Run all hooks manually

# CI/CD
# GitHub Actions runs automatically on push/PR
# See .github/workflows/ci.yml
```

## Technology Stack Quick Reference

| Layer | Technology | Notes |
|-------|-----------|-------|
| Language | Swift 5.9+ | Strict type safety, modern concurrency |
| UI Framework | SwiftUI | Declarative, native macOS UI |
| System Integration | AppKit | Menu bar, hotkeys, accessibility APIs |
| Audio | AVFoundation | AVAudioEngine for 16kHz mono capture |
| ML/ASR | FluidAudio SDK | Local speech-to-text, 25 languages |
| Testing | XCTest | Native Swift testing framework |
| Code Quality | SwiftLint | Static analysis and style enforcement |
| Build System | Swift Package Manager | Dependency management |
| CI/CD | GitHub Actions | Automated testing and quality checks |

## Key Dependencies

- **FluidAudio** (main branch): Local speech-to-text SDK leveraging Apple Neural Engine
- **ViewInspector** (v0.10.0+): SwiftUI testing library for crash detection tests
- **AVFoundation**: Audio capture and processing
- **ApplicationServices**: Accessibility APIs for text insertion
- **Carbon**: Global hotkey registration

## Testing Strategy

The project uses a multi-layered testing approach:

### 1. Unit Tests (XCTest)
- Logic and state transitions
- Service layer behavior
- Model validation
- Run via `swift test --parallel`

### 2. Crash Detection Tests (ViewInspector)
- Test that views/ViewModels can be instantiated without runtime crashes
- Catches @Observable + actor existential issues that only manifest at runtime
- See `Tests/SpeechToTextTests/Views/RecordingModalRenderTests.swift`

```swift
func test_recordingModal_instantiatesWithoutCrash() {
    let modal = RecordingModal()
    XCTAssertNotNil(modal)
}
```

### 3. E2E Tests (XCUITest)
- Full user flows (onboarding, recording, settings)
- Permission dialog handling
- Located in `UITests/SpeechToTextUITests.swift`
- Run via `./scripts/run-ui-tests.sh` (macOS only)

### 4. Local Smoke Tests
- Brief app runs checking for crashes
- Must run on actual macOS hardware
- Run via `./scripts/smoke-test.sh --build --duration 5`

## Scripts Reference

Located in `scripts/` directory. All require macOS to run.

| Script | Purpose | Key Flags |
|--------|---------|-----------|
| `build-app.sh` | Build signed .app bundle | `--sync` (rsync to remote Mac), `--skip-tests` |
| `smoke-test.sh` | Quick crash detection | `--build`, `--duration <sec>` |
| `run-ui-tests.sh` | Run XCUITest E2E suite | Requires built app |
| `remote-test.sh` | Run tests on remote Mac | Requires SSH config |
| `setup-signing.sh` | Configure code signing | Interactive prompts |
| `export-dmg.sh` | Create distributable DMG | Requires signed app |
| `create-issues.sh` | Create GitHub issues from specs | Reads from `specs/` |

### Remote Testing Workflow
For CI or when developing on non-macOS:
```bash
# 1. Setup SSH to your Mac (one-time)
./scripts/setup-ssh-for-mac.sh

# 2. Build and sync to remote Mac
./scripts/build-app.sh --sync

# 3. Run tests remotely
./scripts/remote-test.sh
```

### Concurrency Safety Patterns

**CRITICAL**: Review [`.claude/references/concurrency.md`](references/concurrency.md) before writing concurrency code. The legacy `docs/CONCURRENCY_PATTERNS.md` now redirects there.

#### 1. @Observable + Actor Existential (EXC_BAD_ACCESS)
```swift
// WRONG - Crashes
@Observable class ViewModel {
    private let service: any MyActorProtocol
}

// CORRECT - Use @ObservationIgnored
@Observable class ViewModel {
    @ObservationIgnored private let service: any MyActorProtocol
}
```

#### 2. Audio Callbacks + @MainActor (Actor Isolation Crash)
```swift
// WRONG - Crashes when audio callback hits MainActor method
@MainActor class AudioService {
    func processBuffer(_ buffer: AVAudioPCMBuffer) { ... }
}

// CORRECT - Use nonisolated + Task hop
@MainActor class AudioService {
    private nonisolated(unsafe) let counter = ThreadSafeCounter()

    private nonisolated func processBuffer(_ buffer: AVAudioPCMBuffer) {
        Task { @MainActor [weak self] in ... }
    }
}
```

#### 3. AVAudioEngine Format (Engine Start Failure)
```swift
// WRONG - May fail on some hardware
let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, ...)

// CORRECT - Use native format, convert manually
let nativeFormat = inputNode.outputFormat(forBus: 0)
```

**SwiftLint Custom Rules**:
- `observable_actor_existential_warning`: Detects actor existentials in @Observable without @ObservationIgnored
- `nonisolated_unsafe_warning`: Flags nonisolated(unsafe) usage for review

## Asking Questions

If you need to ask the user a question, use the `AskUserQuestion` tool. This is especially useful during:
- `speckit.clarify` workflows
- Architectural decisions with multiple valid approaches
- Clarifying user preferences or requirements

## Updating AGENTS.md Files

When you discover new information that would be helpful for future development work, please:

- **Update existing AGENTS.md files** when you learn implementation details, debugging insights, or architectural patterns specific to that component
- **Create new AGENTS.md files** in relevant directories when working with areas that don't yet have documentation
- **Add valuable insights** such as:
  - Common pitfalls in Swift/macOS development
  - Actor isolation and concurrency debugging techniques
  - SwiftUI + AppKit integration patterns
  - FluidAudio SDK usage patterns
  - Accessibility API considerations
  - Memory management patterns (especially with Carbon APIs)
  - Testing strategies for async/actor code

## Design Aesthetic: "Warm Minimalism"

This project follows a **Warm Minimalism** design language:
- Frosted glass modals (`.ultraThinMaterial`)
- Amber color palette (AmberLight, AmberPrimary, AmberBright)
- Spring animations (response: 0.5, damping: 0.7)
- Minimal chrome, content-focused
- Floating window level for modals

When creating new UI components, adhere to this aesthetic for consistency.
