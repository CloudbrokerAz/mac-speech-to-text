import AVFoundation
import FluidAudio
import Foundation
import OSLog

/// Result of transcription
struct TranscriptionResult: Sendable {
    let text: String
    let confidence: Float
    let durationMs: Int
}

/// Protocol for FluidAudio service (enables mocking for tests)
protocol FluidAudioServiceProtocol: Actor {
    func initialize(language: String) async throws
    func transcribe(samples: [Int16], sampleRate: Double) async throws -> TranscriptionResult
    func switchLanguage(to language: String) async throws
    func getCurrentLanguage() -> String
    func checkInitialized() -> Bool
    func shutdown()
}

/// Errors specific to FluidAudio integration
enum FluidAudioError: Error, LocalizedError, Sendable, Equatable {
    case notInitialized
    case modelNotLoaded
    case initializationFailed(String)
    case transcriptionFailed(String)
    case invalidAudioFormat
    case languageNotSupported(String)

    var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "FluidAudio service has not been initialized"
        case .modelNotLoaded:
            return "Language model has not been loaded"
        case .initializationFailed(let message):
            return "Failed to initialize FluidAudio: \(message)"
        case .transcriptionFailed(let message):
            return "Transcription failed: \(message)"
        case .invalidAudioFormat:
            return "Invalid audio format. Expected 16kHz mono Int16 samples"
        case .languageNotSupported(let lang):
            return "Language '\(lang)' is not supported"
        }
    }
}

/// Swift actor wrapping FluidAudio SDK for thread-safe ASR.
///
/// ## Reentrancy contract for `asrManager`
///
/// `AsrManager` (FluidAudio SDK) is a non-`Sendable`, non-actor `final
/// class` that mutates internal decoder state (`microphoneDecoderState`
/// / `systemDecoderState`) via `inout` during its own `transcribe(_:)`
/// awaits. FluidAudio's docs are explicit that "stateless decoding"
/// only holds *across serialised calls* — concurrent calls would race
/// the decoder.
///
/// Swift actors are reentrant: while `transcribe()` is suspended at
/// `await asrManager.transcribe(...)`, another actor-isolated method
/// (`shutdown()`, a second `transcribe()`) can run on the same actor
/// instance. Without an explicit guard, two concurrent transcribes
/// inside one `FluidAudioService` would race the same `AsrManager`.
///
/// We address this with two pieces:
///
/// 1. `asrManager` is `nonisolated(unsafe)`. Reads and writes of the
///    property happen only inside actor-isolated methods (`initialize`,
///    `runTranscribe`, `shutdown`), so the actor's own execution-turn
///    serialisation makes the access race-free; the attribute only
///    suppresses the cross-isolation `[#SendingRisksDataRace]` check
///    at the inner await site. The warning was the compiler's hint at
///    the reentrancy hazard, not the hazard itself. See
///    `.claude/references/concurrency.md` §2.
/// 2. `transcribeInFlight` + `transcribeWaiters` form a single-flight
///    queue. A second `transcribe()` while one is already running
///    suspends on a continuation until the active call's `defer` hands
///    the slot off — no parallel access to `AsrManager` is possible.
///
/// ## Maintenance contract
///
/// **Any new `await asrManager.<method>(...)` call site outside
/// `runTranscribe` must either be synchronous (no await) or take the
/// same single-flight slot.** The `nonisolated(unsafe)` attribute
/// means the compiler will not warn about new violations; new call
/// sites must hold the slot via `transcribe(samples:sampleRate:)`'s
/// wrapper or factor a comparable guard for their own surface.
actor FluidAudioService: FluidAudioServiceProtocol {
    /// `nonisolated(unsafe)` because `AsrManager` is a non-`Sendable`,
    /// non-actor third-party `final class` that we hold exclusively
    /// inside this actor. The cross-isolation `sending` check at
    /// `await asrManager.transcribe(...)` would otherwise fire because
    /// the compiler can't see that the single-flight guard below
    /// (`transcribeInFlight` + `transcribeWaiters`) prevents concurrent
    /// access. Reads and writes of the property are nonisolated, but
    /// every caller (`initialize`, `runTranscribe`, `shutdown`) is
    /// itself actor-isolated, so accesses are serialised by the actor's
    /// own execution turns. See the type-level "Maintenance contract".
    private nonisolated(unsafe) var asrManager: AsrManager?

    /// Single-flight serialisation for `transcribe()`. The flag is set
    /// while a `runTranscribe` body is executing; reentrant callers
    /// suspend on a continuation in `transcribeWaiters` until the active
    /// call's `defer` hands the slot off. We use this explicit queue
    /// (rather than a `Task` handle) so each waiter receives the slot
    /// from its predecessor in well-defined FIFO order — no risk of a
    /// completed-Task `await` returning before the holder's defer has
    /// cleared the flag, no busy-loop on contention.
    ///
    /// The continuation type is `<Void, Error>` (throwing) so
    /// `shutdown()` can `resume(throwing: .notInitialized)` to drain
    /// waiters. Drained waiters throw at the await site and never
    /// reach `runTranscribe` — even if a concurrent `initialize(...)`
    /// re-arms `asrManager` between drain and wake, two drained
    /// waiters can never race on the same `AsrManager` instance.
    private var transcribeInFlight: Bool = false
    private var transcribeWaiters: [CheckedContinuation<Void, Error>] = []

    private var currentLanguage: String = "en"
    private var models: AsrModels?
    private var isInitialized = false
    private let serviceId: String
    private var transcriptionCount: Int = 0

    /// Simulated error for testing (from launch arguments)
    private let simulatedError: SimulatedErrorType?

    /// Test-only delay injected at the top of `runTranscribe` (after slot
    /// acquisition). When non-zero, the active transcribe holds the
    /// single-flight slot for at least this long — long enough for the
    /// reentrancy-guard tests to force the queue's wait path. Always
    /// `.zero` in production via the public `init()`.
    private let transcribeSimulatedDelay: Duration

    init() {
        self.init(simulatedError: LaunchArguments.simulatedError)
    }

    /// Internal designated init. Tests use this to inject a
    /// `transcribeSimulatedDelay` so the wait path of the single-flight
    /// guard is genuinely exercised (rather than every caller racing
    /// past the slot synchronously).
    internal init(
        simulatedError: SimulatedErrorType?,
        transcribeSimulatedDelay: Duration = .zero
    ) {
        serviceId = UUID().uuidString.prefix(8).description
        self.simulatedError = simulatedError
        self.transcribeSimulatedDelay = transcribeSimulatedDelay
        AppLogger.service.debug("FluidAudioService[\(self.serviceId, privacy: .public)] created")
        if let error = simulatedError {
            AppLogger.service.debug("FluidAudioService[\(self.serviceId, privacy: .public)] will simulate error: \(error.rawValue, privacy: .public)")
        }
    }

    /// Initialize FluidAudio with specified language
    func initialize(language: String = "en") async throws {
        AppLogger.info(AppLogger.service, "[\(serviceId)] initialize(language: \(language)) called")

        // Check for simulated model loading error
        if simulatedError == .modelLoading {
            AppLogger.error(AppLogger.service, "[\(serviceId)] Simulating model loading error")
            throw FluidAudioError.initializationFailed("Simulated model loading failure for testing")
        }

        guard !isInitialized else {
            AppLogger.debug(AppLogger.service, "[\(serviceId)] Already initialized, skipping")
            return
        }

        do {
            // Download and load models (FluidAudio handles caching)
            AppLogger.debug(AppLogger.service, "[\(serviceId)] Downloading/loading ASR models (v3)...")
            let startTime = CFAbsoluteTimeGetCurrent()
            let models = try await AsrModels.downloadAndLoad(version: .v3)
            let modelLoadTime = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
            self.models = models
            AppLogger.info(AppLogger.service, "[\(serviceId)] Models loaded in \(modelLoadTime)ms")

            // Initialize ASR manager with default config
            AppLogger.debug(AppLogger.service, "[\(serviceId)] Creating ASR manager with default config...")
            let config = ASRConfig.default
            let manager = AsrManager(config: config)

            AppLogger.debug(AppLogger.service, "[\(serviceId)] Initializing ASR manager...")
            let initStartTime = CFAbsoluteTimeGetCurrent()
            try await manager.initialize(models: models)
            let initTime = Int((CFAbsoluteTimeGetCurrent() - initStartTime) * 1000)
            AppLogger.info(AppLogger.service, "[\(serviceId)] ASR manager initialized in \(initTime)ms")

            self.asrManager = manager
            self.currentLanguage = language
            self.isInitialized = true
            AppLogger.info(AppLogger.service, "[\(serviceId)] FluidAudio initialization complete")
        } catch {
            AppLogger.error(AppLogger.service, "[\(serviceId)] Initialization failed: \(error.localizedDescription)")
            throw FluidAudioError.initializationFailed(error.localizedDescription)
        }
    }

    /// Transcribe audio samples at the given sample rate.
    ///
    /// Reentrant calls are serialised via `transcribeInFlight` +
    /// `transcribeWaiters` — see the type-level note on `asrManager`.
    /// In practice every production consumer (`RecordingViewModel`,
    /// `VoiceTriggerMonitoringService`) owns its own `FluidAudioService`,
    /// so reentrancy is unreachable; the guard exists for runtime
    /// safety against future refactors and to satisfy strict-concurrency
    /// checking.
    ///
    /// - Parameters:
    ///   - samples: Int16 audio samples at the native sample rate
    ///   - sampleRate: The sample rate of the input audio (e.g., 48000.0)
    func transcribe(samples: [Int16], sampleRate: Double) async throws -> TranscriptionResult {
        // Defer-first ownership pattern: register the release before any
        // throwing/awaiting code. `holdsSlot` tracks whether *this* call
        // owns the slot, so a fast-fail path that throws before
        // acquisition (e.g. a cancellation or future precondition check
        // here) doesn't strand the slot.
        var holdsSlot = false
        defer {
            if holdsSlot {
                if !transcribeWaiters.isEmpty {
                    // Hand the slot to the next waiter (keeping the flag
                    // true so a third caller racing in here observes "in
                    // flight" and queues up). The `removeFirst()` +
                    // `resume()` pair is non-suspending; actor isolation
                    // guarantees no reentry between them. The woken
                    // waiter's Task is *scheduled* by `resume()`, not run
                    // synchronously.
                    let next = transcribeWaiters.removeFirst()
                    next.resume()
                } else {
                    transcribeInFlight = false
                }
            }
        }

        // Acquire the slot. Cancellation here is propagated immediately —
        // a cancelled caller never queues, never blocks the next legitimate
        // caller. (Once queued, cancellation is cooperative; see
        // `runTranscribe`'s `Task.checkCancellation()` for the wake path.)
        try Task.checkCancellation()

        if transcribeInFlight {
            AppLogger.warning(
                AppLogger.service,
                "[\(self.serviceId)] reentrant transcribe(); awaiting prior call (queue depth: \(transcribeWaiters.count + 1))"
            )
            // Throwing continuation: a clean hand-off resumes with
            // success and we fall through to `holdsSlot = true`. A
            // `shutdown()`-driven drain resumes with
            // `FluidAudioError.notInitialized`, which throws here —
            // `holdsSlot` stays false, the defer is a no-op, and we
            // never reach `runTranscribe`. This closes the
            // drain-then-reinit race where a re-armed `asrManager`
            // could otherwise let two drained waiters race the SDK.
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                transcribeWaiters.append(cont)
            }
            // Slot was handed off to us by the prior caller's defer above;
            // `transcribeInFlight` is already true on our behalf.
        } else {
            transcribeInFlight = true
        }
        holdsSlot = true

        return try await runTranscribe(samples: samples, sampleRate: sampleRate)
    }

    /// Body of `transcribe(samples:sampleRate:)`. Always invoked with the
    /// in-flight slot held by the public entry point — never call this
    /// directly.
    private func runTranscribe(samples: [Int16], sampleRate: Double) async throws -> TranscriptionResult {
        // Cancellation check on the *wake* path: if the caller's Task was
        // cancelled while queued in `transcribeWaiters`, bail before
        // doing the resample/ASR work. `withCheckedContinuation` itself
        // is non-cancelling, so this is the gate that limits the cost of
        // a cancelled caller waking from the queue.
        try Task.checkCancellation()

        // Test-only: hold the slot long enough for the reentrancy-guard
        // tests to force concurrent callers to queue. Production paths
        // see `.zero` and the helper returns immediately.
        try await applyTranscribeSimulatedDelay()

        transcriptionCount += 1
        let transcriptionId = transcriptionCount

        AppLogger.info(AppLogger.service, "[\(serviceId)] transcribe #\(transcriptionId): \(samples.count) samples at \(Int(sampleRate))Hz")

        // Check for simulated transcription error
        if simulatedError == .transcription {
            AppLogger.error(AppLogger.service, "[\(serviceId)] Simulating transcription error")
            throw FluidAudioError.transcriptionFailed("Simulated transcription failure for testing")
        }

        guard let asrManager = asrManager else {
            AppLogger.error(AppLogger.service, "[\(serviceId)] transcribe #\(transcriptionId): NOT INITIALIZED")
            throw FluidAudioError.notInitialized
        }

        guard !samples.isEmpty else {
            AppLogger.error(AppLogger.service, "[\(serviceId)] transcribe #\(transcriptionId): empty samples")
            throw FluidAudioError.invalidAudioFormat
        }

        let startTime = CFAbsoluteTimeGetCurrent()

        do {
            // Convert Int16 samples to Float (FluidAudio expects Float in range [-1.0, 1.0])
            AppLogger.debug(AppLogger.service, "[\(serviceId)] transcribe #\(transcriptionId): converting to float...")
            let floatSamples = samples.map { Float($0) / 32768.0 }

            // Resample to 16kHz if needed using FluidAudio's AudioConverter
            let finalSamples: [Float]
            let targetSampleRate = Double(Constants.Audio.sampleRate)

            if abs(sampleRate - targetSampleRate) > 1.0 {
                // Need to resample: create AVAudioPCMBuffer and use AudioConverter
                AppLogger.debug(AppLogger.service, "[\(serviceId)] transcribe #\(transcriptionId): Resampling from \(Int(sampleRate))Hz to \(Int(targetSampleRate))Hz...")

                guard let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else {
                    throw FluidAudioError.invalidAudioFormat
                }

                guard let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(floatSamples.count)) else {
                    throw FluidAudioError.invalidAudioFormat
                }
                buffer.frameLength = AVAudioFrameCount(floatSamples.count)

                // Copy float samples into buffer
                if let channelData = buffer.floatChannelData {
                    for index in 0..<floatSamples.count {
                        channelData[0][index] = floatSamples[index]
                    }
                }

                // Use FluidAudio's AudioConverter to resample
                let audioConverter = AudioConverter()
                finalSamples = try audioConverter.resampleBuffer(buffer)
                AppLogger.debug(AppLogger.service, "[\(serviceId)] transcribe #\(transcriptionId): Resampled \(floatSamples.count) samples -> \(finalSamples.count) samples")
            } else {
                // Already at 16kHz
                finalSamples = floatSamples
            }

            // Log sample statistics for debugging
            if AppLogger.currentLevel >= .trace && !finalSamples.isEmpty {
                let minVal = finalSamples.min() ?? 0
                let maxVal = finalSamples.max() ?? 0
                let avgVal = finalSamples.reduce(0, +) / Float(finalSamples.count)
                AppLogger.trace(
                    AppLogger.service,
                    "[\(serviceId)] transcribe #\(transcriptionId): sample stats min=\(minVal) max=\(maxVal) avg=\(avgVal)"
                )
            }

            // Perform transcription
            AppLogger.debug(AppLogger.service, "[\(serviceId)] transcribe #\(transcriptionId): calling ASR with \(finalSamples.count) samples at 16kHz...")
            let result = try await asrManager.transcribe(finalSamples)

            let durationMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)

            // FluidAudio SDK returns confidence score directly (non-optional in v3)
            let confidence: Float = result.confidence

            AppLogger.info(
                AppLogger.service,
                "[\(serviceId)] transcribe #\(transcriptionId): completed in \(durationMs)ms, confidence=\(confidence), text=\"\(result.text.prefix(50))...\""
            )

            return TranscriptionResult(
                text: result.text,
                confidence: confidence,
                durationMs: durationMs
            )
        } catch {
            let durationMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
            AppLogger.error(
                AppLogger.service,
                "[\(serviceId)] transcribe #\(transcriptionId): FAILED after \(durationMs)ms: \(error.localizedDescription)"
            )
            throw FluidAudioError.transcriptionFailed(error.localizedDescription)
        }
    }

    /// Test-only seam used by `runTranscribe` to hold the single-flight
    /// slot for `transcribeSimulatedDelay` before doing any work.
    /// Production paths configure `.zero`, making this a no-op.
    private func applyTranscribeSimulatedDelay() async throws {
        guard transcribeSimulatedDelay != .zero else { return }
        try await Task.sleep(for: transcribeSimulatedDelay)
    }

    /// Switch to a different language
    /// Note: Parakeet TDT v3 is multilingual, so no model reload is needed
    func switchLanguage(to language: String) async throws {
        AppLogger.info(AppLogger.service, "[\(serviceId)] switchLanguage from \(currentLanguage) to \(language)")

        guard SupportedLanguage.isSupported(language) else {
            AppLogger.error(AppLogger.service, "[\(serviceId)] Language not supported: \(language)")
            throw FluidAudioError.languageNotSupported(language)
        }

        // FluidAudio Parakeet TDT v3 supports all 25 European languages
        // No need to reload model - it's multilingual
        let oldLanguage = currentLanguage
        currentLanguage = language
        AppLogger.debug(AppLogger.service, "[\(serviceId)] Language switched: \(oldLanguage) -> \(language)")
    }

    /// Get current language
    func getCurrentLanguage() -> String {
        currentLanguage
    }

    /// Check if service is initialized
    func checkInitialized() -> Bool {
        isInitialized
    }

    /// Shutdown and clean up resources
    func shutdown() {
        AppLogger.info(AppLogger.service, "[\(serviceId)] shutdown() called, \(transcriptionCount) transcriptions performed")

        // Drain any queued waiters so their `CheckedContinuation`s don't
        // leak (the runtime would surface a "leaked checked continuation"
        // warning on actor teardown) and their callers don't hang forever.
        // We `resume(throwing: .notInitialized)` so drained waiters throw
        // at their await site and never reach `runTranscribe` — closes
        // the race where a concurrent re-`initialize(...)` could
        // otherwise let two drained waiters race the freshly-armed
        // `AsrManager`.
        let stranded = transcribeWaiters
        transcribeWaiters.removeAll()
        transcribeInFlight = false
        for cont in stranded {
            cont.resume(throwing: FluidAudioError.notInitialized)
        }

        asrManager = nil
        models = nil
        isInitialized = false
        currentLanguage = "en"
        AppLogger.debug(AppLogger.service, "[\(serviceId)] Shutdown complete")
    }
}
