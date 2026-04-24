# MLX Model Lifecycle

> **Load this when:** implementing the local LLM provider (#3), the
> clinical-notes processor (#5), the model-download / first-run UX, or
> the eventual migration to Gemma 4 E4B (tracked in #18 and upstream
> [`ml-explore/mlx-swift#389`](https://github.com/ml-explore/mlx-swift/issues/389)).

Design reference for running a local LLM in-process via
[`mlx-swift-examples`](https://github.com/ml-explore/mlx-swift-examples)
on Apple Silicon.

---

## Model choice (locked)

- **v1**: **Gemma 3 4B-IT** (MLX 4-bit). Quality/speed balance is good
  enough for SOAP-note JSON extraction on 16 GB+ Apple Silicon.
- **v2 (blocked)**: **Gemma 4 E4B-IT**. MLX Swift lacks the `gemma4`
  architecture registration as of 2026-04-24
  ([`mlx-swift#389`](https://github.com/ml-explore/mlx-swift/issues/389)).
  Migration PR tracked in #18; one-config swap once upstream lands.
- Provider is abstracted behind `LLMProvider` (issue #3) so swapping
  the model is a configuration change, not a refactor.

---

## Deployment

- **Bundled in the `.app`**: the 4-bit Gemma 3 4B-IT weights ship in
  `Resources/Models/gemma-3-4b-it-4bit/` (~2.5 GB). DMG distribution,
  not App Store.
- **Git LFS vs build-time download**: decide in #3's PR. LFS keeps the
  repo self-contained but bloats clone size. Build-time download from
  the `mlx-community` Hugging Face org is smaller at `git clone` time
  but adds a network hop to the first build.

---

## Load / warmup / unload

`MLXGemmaProvider` is an actor. Two-phase init:

1. **Lazy load** on first inference call. Reading 2.5 GB of weights off
   disk into unified memory is the expensive step (~10–15 s cold on
   M-series).
2. **`warmup()`** can be awaited proactively when the user enables
   Clinical Notes Mode in Settings, so the first "Generate Notes" tap
   doesn't pay the load cost.

Unload policy for v1: keep the model loaded once it's in memory. Don't
evict on idle — warming it up is expensive. Revisit if memory pressure
surfaces on smaller Macs.

---

## Inference defaults

Deterministic by design:

```swift
LLMOptions(
    temperature: 0,        // no sampling randomness
    topP: 1.0,
    maxTokens: 1024,
    seed: 42,              // fixed seed
    stop: ["}"]            // optional — trims after JSON close brace
)
```

The prompt builder (#4) assembles input; the processor (#5) handles
retry on schema failure.

---

## Concurrency

- `MLXGemmaProvider` is an `actor`. Only one inference runs at a time —
  the GPU/ANE doesn't parallelise a single model's requests well, and
  sequentialising at the actor layer keeps the memory pressure story
  simple.
- Callers cross the actor boundary via `await`. If a UI callback is on
  `@MainActor`, `await provider.generate(…)` is the right shape — don't
  try to hop threads manually.
- Stored on an `@Observable` class (e.g. `AppState`): requires
  `@ObservationIgnored`, per [`concurrency.md`](concurrency.md) rule 1.

---

## Memory pressure

Gemma 3 4B-IT @ 4-bit needs ~3 GB resident. On 8 GB Macs (unsupported
baseline officially — minimum is 16 GB), running the model alongside
Safari and an IDE will hit swap.

- Document the recommended hardware (16 GB+).
- For 8 GB machines, consider surfacing a "low memory" setting that
  swaps to a smaller model (or Apple Foundation Models on macOS 26+).
- Never hard-crash the app on memory pressure — catch the MLX load
  error and surface it via the "LLM failed, showing raw transcript"
  fallback (#5).

---

## Failure fallback

Per #5 acceptance:
- LLM load failure → "Clinical Notes unavailable on this device" with a
  link to the diagnostic / logs.
- LLM inference throws → `.rawTranscriptFallback(reason:)`. The doctor
  still gets the transcript and can edit manually.
- JSON schema failure → retry once; failure on the retry →
  `.rawTranscriptFallback`.

---

## Privacy

- The LLM is in-process; no weights or prompts leave the device.
- Prompts contain PHI (the transcript). Apply
  [`phi-handling.md`](phi-handling.md) rules to any logging around the
  provider — log structural metadata only (token counts, latency,
  retry counter). Never log the prompt or the response body.

---

## Upstream tracking

- **`ml-explore/mlx-swift#389`** — Gemma 4 architecture support. Until
  this lands (or we port it ourselves / adopt a community fork),
  Gemma 4 E4B cannot be loaded in Swift. Python MLX has day-0 support;
  the Swift binding does not.
- **`unsloth/gemma-4-E4B-it-MLX-*bit`** and
  `mlx-community/gemma-4-E4B-it-*bit` — pre-quantised weights waiting
  for the Swift side.
- **`SharpAI/SwiftLM`** — a community Swift MLX fork that does
  register `gemma4`. HTTP-server-shaped; considered and rejected for
  bundled-in-app shipping (see #19 decision matrix).

---

## Related issues

- #3 — `LLMProvider` protocol + `MLXGemmaProvider`.
- #4 — prompt builder + JSON schema guard.
- #5 — `ClinicalNotesProcessor` orchestrator.
- #18 — Gemma 4 E4B migration tracker.
