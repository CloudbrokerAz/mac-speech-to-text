# Concurrency Reference

> **Load this when:** writing or reviewing code that uses `@Observable`,
> Swift actors, `@MainActor`, Core Audio callbacks, `Task { }`, or any
> nonisolated(unsafe) property. SwiftLint rules
> `observable_actor_existential_warning` and `nonisolated_unsafe_warning`
> point at the patterns here.

This file supersedes the older `docs/CONCURRENCY_PATTERNS.md` (which now
redirects here).

---

## 1. `@Observable` + actor existential (EXC_BAD_ACCESS)

An `@Observable` class that stores an `any SomeActorProtocol` property
crashes on ARM64 with `KERN_INVALID_ADDRESS` (possible pointer
authentication failure) the first time the Observation macro scans it.

```swift
// WRONG — crashes
@Observable
class MyViewModel {
    private let service: any MyActorProtocol
}

// CORRECT
@Observable
class MyViewModel {
    @ObservationIgnored private let service: any MyActorProtocol
}
```

**Detection:** SwiftLint custom rule `observable_actor_existential_warning`.

---

## 2. `nonisolated(unsafe)` — when it's the right call

`nonisolated(unsafe)` opts out of compiler concurrency checking. That's
legitimately necessary in three scenarios:

1. **`deinit` cleanup.** `deinit` runs nonisolated, so any resource held
   by a `@MainActor`-isolated class that needs cleanup there must be
   reachable from nonisolated context.
2. **Audio / system callbacks.** Core Audio taps execute on a real-time
   thread with no actor context.
3. **Thread-safe types you own.** If the property is a type that handles
   its own synchronisation (e.g. an `NSLock`-guarded counter, or a value
   type used immutably), `nonisolated(unsafe)` is safe.

```swift
@Observable @MainActor
class MyViewModel {
    private var timer: Timer?

    // Reachable from deinit, which is nonisolated.
    @ObservationIgnored
    private nonisolated(unsafe) var deinitTimer: Timer?

    func startTimer() {
        let newTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in /* … */ }
        timer = newTimer
        deinitTimer = newTimer
    }

    deinit {
        deinitTimer?.invalidate()
    }
}
```

**Detection:** SwiftLint custom rule `nonisolated_unsafe_warning` flags
every usage so a reviewer inspects the synchronisation story.

---

## 3. Audio callbacks + `@MainActor` (actor-isolation crash)

`AVAudioEngine.inputNode.installTap` callbacks run on an audio thread.
Calling a `@MainActor` method directly from the callback crashes.

```swift
// WRONG — crashes
@MainActor
class AudioCaptureService {
    func processBuffer(_ buffer: AVAudioPCMBuffer) { /* … */ }

    func start() {
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            self.processBuffer(buffer)   // audio thread → MainActor
        }
    }
}

// CORRECT
@MainActor
class AudioCaptureService {
    // Thread-safe helpers that the audio thread can touch directly.
    private nonisolated(unsafe) let pendingWrites = PendingWritesCounter()
    private nonisolated(unsafe) let throttler = AudioLevelThrottler()

    func start() {
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.processBuffer(buffer)
        }
    }

    // Runs on the audio thread. No MainActor calls, no await.
    private nonisolated func processBuffer(_ buffer: AVAudioPCMBuffer) {
        let samples = convertToInt16(buffer)
        pendingWrites.increment()
        Task { @MainActor [weak self] in
            defer { self?.pendingWrites.decrement() }
            await self?.streamingBuffer?.append(samples)
        }
    }
}
```

**Rules:**
- Audio callback code must be `nonisolated` (can't `await`).
- Hop to `MainActor` via `Task { @MainActor … }` for state updates.
- Helpers the callback touches must be `Sendable` (or `@unchecked Sendable` with a synchronisation story).

---

## 4. `AVAudioEngine` format compatibility

Forcing a non-native format on `installTap` can make `audioEngine.start()`
throw on some hardware.

```swift
// WRONG — may fail
let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)
inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { /* … */ }

// CORRECT — native format, convert in callback
let nativeFormat = inputNode.outputFormat(forBus: 0)
inputNode.installTap(onBus: 0, bufferSize: 1024, format: nativeFormat) { buffer, _ in
    if let floatData = buffer.floatChannelData {
        let samples = floatData[0].map { Int16($0 * Float(Int16.max)) }
        // forward samples…
    }
}
```

---

## 5. SwiftUI task lifecycle

`Task { }` launched from `onAppear` can outlive the view and touch a
deallocated view model. Use `.task(id:)` instead — SwiftUI cancels it on
view disappear.

```swift
struct MyView: View {
    @State private var taskId: UUID?

    var body: some View {
        Text("Hello")
            .task(id: taskId) {
                guard taskId != nil else { return }
                // Auto-cancelled on disappear.
            }
            .onAppear { taskId = UUID() }
    }
}
```

---

## 6. Actor protocols for mockability

Swift actors cannot be subclassed, so test-doubles can't inherit. Use a
protocol constrained to `Actor`.

```swift
protocol FluidAudioServiceProtocol: Actor {
    func transcribe(samples: [Int16]) async throws -> TranscriptionResult
}

actor FluidAudioService: FluidAudioServiceProtocol { /* … */ }
actor MockFluidAudioService: FluidAudioServiceProtocol { /* … */ }
```

Stored on an `@Observable` class? Remember `@ObservationIgnored` (rule 1).

---

## 7. What the tests can and can't catch

Unit + ViewInspector tests catch most isolation bugs. These only surface
on real hardware:

- ARM64 pointer-authentication failures.
- Race conditions under sustained load.
- Some SwiftUI rendering paths.

Add a **render crash test** for every new `@Observable` view model:

```swift
func test_myViewModel_instantiatesWithoutCrash() {
    let viewModel = MyViewModel()
    XCTAssertNotNil(viewModel)
}
```

`Tests/SpeechToTextTests/Views/RecordingModalRenderTests.swift` is the
reference pattern.

---

## Checklist: adding an actor-backed service

- [ ] Conform to an `Actor`-constrained protocol (not the concrete type).
- [ ] Store on any `@Observable` class with `@ObservationIgnored`.
- [ ] Provide an actor-typed mock for tests.
- [ ] Add a ViewInspector render crash test for any view that uses it.
- [ ] If a callback (audio, Carbon, `DispatchSource`) touches state, split
      the nonisolated entry from the `@MainActor` side via `Task`.
- [ ] Run `swift test --parallel` plus a local smoke test on real hardware
      before merging — `@Observable`+actor crashes don't always reproduce
      in unit tests.

---

## Related files

- `.swiftlint.yml` — custom rules for these patterns.
- `Tests/SpeechToTextTests/Views/RecordingModalRenderTests.swift` — render crash pattern.
- `.github/workflows/ci.yml` — CI filters (hardware-dependent tests skipped in CI).
