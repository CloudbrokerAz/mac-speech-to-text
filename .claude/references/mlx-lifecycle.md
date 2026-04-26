# MLX Model Lifecycle

> **Load this when:** implementing or modifying the local LLM provider
> (`MLXGemmaProvider`, originally #3, migrated to Gemma 4 E4B in #18),
> the clinical-notes processor (#5), the model-download / first-run UX,
> or any future model swap.

Design reference for running a local LLM in-process via
[`ml-explore/mlx-swift-lm`](https://github.com/ml-explore/mlx-swift-lm)
on Apple Silicon. (`mlx-swift-examples` was deprecated in
[`mlx-swift-lm` PR #441](https://github.com/ml-explore/mlx-swift-lm/pull/441),
2025-11.)

---

## Model choice (locked)

- **v2 (current)**: **Gemma 4 E4B-IT** (MLX 4-bit) —
  `mlx-community/gemma-4-e4b-it-4bit`, ~5.2 GB on disk.
  `mlx-swift-lm` 3.31.3 ships native `gemma4` / `gemma4_text` registry
  entries via `LLMTypeRegistry`, including the predefined
  `LLMRegistry.gemma4_e4b_it_4bit` config.
- **v1 (superseded by #18)**: Gemma 3 4B-IT
  (`mlx-community/gemma-3-text-4b-it-4bit`, ~2.6 GB). The migration
  was previously thought to be blocked on
  [`ml-explore/mlx-swift#389`](https://github.com/ml-explore/mlx-swift/issues/389),
  but that issue tracks `gemma4` arch in the lower-level `mlx-swift`
  array/NN package — the actual model registry lives in the companion
  `mlx-swift-lm` package, which has shipped it. The legacy
  `gemma-3-text-4b-it-4bit/` directory in Application Support is
  reclaimed on first launch by `AppState.purgeLegacyGemma3ModelDirectory()`.
- Provider is abstracted behind `LLMProvider` (issue #3) so swapping
  the model is a manifest revision bump — `MLXGemmaProvider` itself is
  model-agnostic.

---

## Deployment

**First-run download with sha256-manifest verification.** *(Updated
2026-04-26 in #3 — supersedes the earlier "bundled in .app" decision.)*

- The bundled `.app` ships only a small JSON manifest at
  `Resources/Models/gemma-4-e4b-it-4bit/manifest.json` (HF revision
  pin + per-file size + sha256 for the LFS-tracked binaries —
  `model.safetensors` and `tokenizer.json`). DMG is ~50 MB — model
  weights stay out.
- `ModelDownloader` (in `Sources/Services/ClinicalNotes/`) fetches
  files from `https://huggingface.co/mlx-community/gemma-4-e4b-it-4bit/resolve/<revision>/`
  on first run, streams sha256 verification, atomically renames into
  `~/Library/Application Support/<bundle-id>/Models/gemma-4-e4b-it-4bit/`.
  Idempotent — re-launches with files present + verified are no-ops.
- `MLXGemmaProvider.warmup()` mmaps the verified directory via
  `MLXLLM.LLMModelFactory.shared.loadContainer(from:using:)`.
- **Why not bundled**: 5.2 GB inside the `.app` would (a) burn GitHub
  LFS bandwidth (10 GiB / month free quota → less than 2 weeks of
  CI), (b) slow every notarisation, (c) force a full new DMG for every
  model swap. Mirrors the existing `FluidAudioService` pattern
  (`AsrModels.downloadAndLoad(version: .v3)`).
- **Trigger UX**: today the download fires lazily on the first
  Generate-Notes tap (with the existing empty-draft fallback if it
  fails). A follow-up PR will move the trigger to the Settings
  Clinical-Notes-Mode toggle so the user opts in *before* the first
  recording, and surfaces progress via `AppState.llmDownloadProgress`
  / `llmDownloadState`.
- **No HF auth needed** for `mlx-community` public weights, so the
  downloader uses `URLSession` with no token plumbing.

---

## Load / warmup / unload

`MLXGemmaProvider` is an actor. Two-phase init:

1. **Lazy load** on first inference call. Reading ~5 GB of weights off
   disk into unified memory is the expensive step (~15–25 s cold on
   M-series for E4B; was ~10–15 s for the smaller v1 Gemma 3 4B).
2. **`warmup()`** can be awaited proactively when the user enables
   Clinical Notes Mode in Settings, so the first "Generate Notes" tap
   doesn't pay the load cost.

Unload policy for v2: keep the model loaded once it's in memory. Don't
evict on idle — warming it up is expensive. Revisit if memory pressure
surfaces on smaller Macs (E4B is roughly 2× v1's resident set).

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

Gemma 4 E4B @ 4-bit needs ~5–6 GB resident (vs ~3 GB for v1 Gemma 3 4B).
On 8 GB Macs (unsupported baseline officially — minimum is 16 GB),
running E4B alongside Safari and an IDE will hit swap hard. The 16 GB
recommended baseline now has less headroom than under v1 — surface
"low-memory mode" considerations earlier if user reports swap pressure.

- Document the recommended hardware (16 GB+; 24 GB+ comfortable for E4B).
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

- **`mlx-swift-lm` 3.31.x** (current dependency) — ships `gemma4` /
  `gemma4_text` registry entries and predefined
  `LLMRegistry.gemma4_e4b_it_4bit` / `gemma4_e2b_it_4bit` configs.
  Future Gemma releases will land here; bumping the dependency to a
  patch release in the 3.31.x line should be a near-zero-touch change.
- **`mlx-community/gemma-4-e4b-it-4bit`** — pinned weights for the
  current v2 deployment. SHA pinned in `manifest.json`.
- **`ml-explore/mlx-swift#389`** — historical: was the wrong tracking
  issue for v2 migration (model registry lives in `mlx-swift-lm`, not
  `mlx-swift`). No longer load-bearing for this project.

---

## Related issues

- #3 — `LLMProvider` protocol + `MLXGemmaProvider` (v1).
- #4 — prompt builder + JSON schema guard.
- #5 — `ClinicalNotesProcessor` orchestrator.
- #18 — v1 → v2 cutover (Gemma 4 E4B-IT).
