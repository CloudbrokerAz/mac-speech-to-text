# Swift Concurrency Patterns and Pitfalls

> **Moved.** This file has been superseded by
> [`.claude/references/concurrency.md`](../.claude/references/concurrency.md),
> part of the topic-router reorganisation in issue #25 (F6). The new
> file covers the same patterns plus more:
>
> - `@Observable` + actor existential types (EXC_BAD_ACCESS)
> - `nonisolated(unsafe)` — when it's the right call
> - Audio callbacks crossing `@MainActor`
> - `AVAudioEngine` format compatibility
> - SwiftUI task lifecycle
> - Actor-constrained protocols for mockability
> - Checklist for adding actor services
>
> This stub is kept so the SwiftLint config comments, `AppState.swift`
> comments, and previous `.claude/CLAUDE.md` references still resolve.
> Please update any new references to point at the new location.
