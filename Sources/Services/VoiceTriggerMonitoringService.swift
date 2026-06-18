// VoiceTriggerMonitoringService.swift
// macOS Local Speech-to-Text Application
//
// Coordinator service for voice trigger (wake word) monitoring.
// Orchestrates WakeWordService, AudioCaptureService, FluidAudioService,
// and TextInsertionService to provide hands-free voice activation.

import AppKit
import AVFoundation
import Foundation
import Observation
import OSLog

// MARK: - Voice Trigger Monitoring Service

/// Coordinator service for voice trigger monitoring
///
/// This service orchestrates the complete voice trigger workflow:
/// 1. Continuously listens for wake words using WakeWordService
/// 2. When a wake word is detected, switches to audio capture mode
/// 3. Monitors for silence to determine when user has finished speaking
/// 4. Transcribes captured audio using FluidAudioService
/// 5. Inserts transcribed text using TextInsertionService
///
/// Thread Safety:
/// - This is a @MainActor class for UI binding compatibility
/// - Service dependencies are @ObservationIgnored to prevent @Observable tracking issues
/// - Audio callbacks use Task dispatch to hop to MainActor
@Observable
@MainActor
final class VoiceTriggerMonitoringService {
    // MARK: - Published State

    /// Current state of the voice trigger workflow
    var state: VoiceTriggerState = .idle

    /// Real-time audio level for visualization (0.0 - 1.0)
    var audioLevel: Double = 0.0

    /// Currently detected keyword (set when wake word is heard)
    var currentKeyword: String?

    /// Time remaining before silence timeout ends capture (nil when not capturing)
    var silenceTimeRemaining: TimeInterval?

    /// Last transcribed text (for display/debugging)
    var lastTranscribedText: String = ""

    /// Last error message for UI display
    var errorMessage: String?

    // MARK: - Dependencies
    // All services are @ObservationIgnored to prevent @Observable from tracking them
    // This is critical for actor existential types which can cause executor check crashes

    @ObservationIgnored private let wakeWordService: any WakeWordServiceProtocol
    @ObservationIgnored private let audioService: AudioCaptureService
    @ObservationIgnored private let fluidAudioService: any FluidAudioServiceProtocol
    @ObservationIgnored private let textInsertionService: TextInsertionService
    @ObservationIgnored private let settingsService: SettingsService

    // MARK: - Private State

    /// Captured audio samples during recording phase (Float for FluidAudio)
    @ObservationIgnored private var capturedSamples: [Int16] = []

    /// Sample rate of captured audio
    @ObservationIgnored private var capturedSampleRate: Double = Double(Constants.Audio.sampleRate)

    /// Path to wake word model (from configuration/bundle)
    @ObservationIgnored private var wakeWordModelPath: String = ""

    /// Timer for silence detection
    @ObservationIgnored private var silenceTimer: Timer?

    /// Timer for max recording duration
    @ObservationIgnored private var maxDurationTimer: Timer?

    /// Last time audio was detected above threshold
    @ObservationIgnored private var lastAudioTime: Date?

    /// Unique ID for logging
    @ObservationIgnored private let serviceId: String

    /// Flag to prevent double state transitions
    @ObservationIgnored private var isTransitioning: Bool = false

    /// Synchronous guard against multiple silence/max-duration timers
    /// enqueueing `handleSilenceTimeout` before the first handler runs
    /// (CON-5). Set before spawning the handler Task; cleared in defer.
    @ObservationIgnored private var isHandlingTimeout: Bool = false

    /// Current voice trigger configuration (cached)
    @ObservationIgnored private var configuration: VoiceTriggerConfiguration = .default

    // nonisolated copies for deinit access (deinit cannot access MainActor-isolated state)
    @ObservationIgnored private nonisolated(unsafe) var deinitSilenceTimer: Timer?
    @ObservationIgnored private nonisolated(unsafe) var deinitMaxDurationTimer: Timer?

    /// Recovery task that transitions from error state back to monitoring
    /// Stored so it can be cancelled during stopMonitoring()
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?

    /// Ordered frame delivery for wake-word processing (CON-2). Per-buffer
    /// `Task` spawns had no FIFO guarantee; a single consumer drains this
    /// stream sequentially so sherpa's streaming decoder sees frames in order.
    @ObservationIgnored private var frameStreamContinuation: AsyncStream<[Float]>.Continuation?
    @ObservationIgnored private var frameConsumerTask: Task<Void, Never>?

    /// Push callback for discrete state transitions (PRF-10).
    @ObservationIgnored var onStateChange: (@MainActor (VoiceTriggerState, VoiceTriggerState) -> Void)?

    /// Idle-eviction task for FluidAudio after monitoring without transcription (PRF-8).
    @ObservationIgnored private var fluidAudioIdleEvictionTask: Task<Void, Never>?

    /// Audio frame payload extracted on the audio thread before MainActor hop.
    private enum IncomingAudioFrame {
        case floatSamples([Float], sampleRate: Double)
        case int16Samples([Int16], sampleRate: Double)
    }

    // MARK: - Initialization

    init(
        wakeWordService: any WakeWordServiceProtocol,
        audioService: AudioCaptureService? = nil,
        fluidAudioService: any FluidAudioServiceProtocol = FluidAudioService(),
        textInsertionService: TextInsertionService = TextInsertionService(),
        settingsService: SettingsService = SettingsService()
    ) {
        self.serviceId = UUID().uuidString.prefix(8).description
        self.wakeWordService = wakeWordService
        self.audioService = audioService ?? AudioCaptureService(settingsService: settingsService)
        self.fluidAudioService = fluidAudioService
        self.textInsertionService = textInsertionService
        self.settingsService = settingsService

        AppLogger.lifecycle(AppLogger.service, self, event: "init[\(serviceId)]")
    }

    deinit {
        // CON-6: Timers are scheduled on RunLoop.main; invalidation must
        // happen on that thread via `stopMonitoring()` before release.
        // AppDelegate and test tearDown await `stopMonitoring()` explicitly.
        // Shadow refs are cleared here only to break retain cycles — no
        // `invalidate()` from a potentially off-main deinit path.
        deinitSilenceTimer = nil
        deinitMaxDurationTimer = nil
        AppLogger.service.debug("VoiceTriggerMonitoringService[\(self.serviceId, privacy: .public)] deallocated")
    }

    // MARK: - Public Methods

    /// Start voice trigger monitoring
    ///
    /// Begins listening for configured wake words. When a wake word is detected,
    /// the service automatically transitions to capturing mode.
    ///
    /// - Throws: VoiceTriggerError if already monitoring or setup fails
    func startMonitoring() async throws {
        AppLogger.info(AppLogger.service, "[\(serviceId)] startMonitoring() called, state=\(state.description)")

        guard !isTransitioning else {
            AppLogger.warning(AppLogger.service, "[\(serviceId)] startMonitoring: transition in progress")
            throw VoiceTriggerError.wakeWordInitFailed("Transition already in progress")
        }

        guard state == .idle else {
            AppLogger.warning(AppLogger.service, "[\(serviceId)] startMonitoring: already active (state=\(state.description))")
            throw VoiceTriggerError.wakeWordInitFailed("Already monitoring")
        }

        isTransitioning = true
        defer { isTransitioning = false }

        // Load configuration
        let settings = settingsService.load()
        configuration = settings.voiceTrigger
        AppLogger.debug(AppLogger.service, "[\(serviceId)] Configuration loaded: \(configuration.keywords.count) keywords, silenceThreshold=\(configuration.silenceThresholdSeconds)s")

        // Clear previous state
        errorMessage = nil
        currentKeyword = nil
        lastTranscribedText = ""
        capturedSamples = []
        silenceTimeRemaining = nil

        do {
            // Configure wake word service with active keywords
            let activeKeywords = configuration.keywords.filter { $0.isEnabled }
            guard !activeKeywords.isEmpty else {
                AppLogger.error(AppLogger.service, "[\(serviceId)] No active keywords configured")
                throw VoiceTriggerError.noKeywordsConfigured
            }

            // Get wake word model path from bundle
            guard let modelPath = Constants.VoiceTrigger.modelPath else {
                AppLogger.error(AppLogger.service, "[\(serviceId)] Wake word model not found in bundle")
                throw VoiceTriggerError.wakeWordInitFailed("Wake word model not found in bundle")
            }
            AppLogger.debug(AppLogger.service, "[\(serviceId)] Wake word model found at: \(modelPath)")
            wakeWordModelPath = modelPath

            // Initialize wake word service with model and keywords
            try await wakeWordService.initialize(modelPath: modelPath, keywords: activeKeywords)

            startFrameConsumer()

            // Start audio capture for wake word processing
            // Pass both level callback (for visualization) and buffer callback (for wake word detection)
            //
            // Capture `serviceId` into a local so the audio-thread closure can interpolate it into
            // the unsupported-format warning without reaching back across the @MainActor boundary
            // for `self.serviceId`. Mirrors the `processorId` capture in AudioBufferProcessor.
            let capturedServiceId = serviceId
            try await audioService.startCapture(
                levelCallback: { @Sendable [weak self] level in
                    Task { @MainActor in self?.handleAudioLevel(level) }
                },
                bufferCallback: { @Sendable [weak self] buffer in
                    // Extract Sendable values on the audio thread before crossing into MainActor.
                    // AVAudioPCMBuffer is non-Sendable; mirrors AudioBufferProcessor.process
                    // (see AudioCaptureService.swift) and .claude/references/concurrency.md §3.
                    let frameLength = Int(buffer.frameLength)
                    let sampleRate = buffer.format.sampleRate

                    if let floatData = buffer.floatChannelData {
                        let floatSamples = Array(UnsafeBufferPointer(start: floatData[0], count: frameLength))
                        Task { @MainActor in
                            self?.handleAudioBuffer(.floatSamples(floatSamples, sampleRate: sampleRate))
                        }
                    } else if let int16Data = buffer.int16ChannelData {
                        let samples = Array(UnsafeBufferPointer(start: int16Data[0], count: frameLength))
                        Task { @MainActor in
                            self?.handleAudioBuffer(.int16Samples(samples, sampleRate: sampleRate))
                        }
                    } else {
                        AppLogger.warning(
                            AppLogger.service,
                            "[\(capturedServiceId)] Unsupported audio format in buffer — frame dropped"
                        )
                    }
                }
            )

            // Transition to monitoring state
            transition(to: .monitoring, context: "startMonitoring")

            AppLogger.info(AppLogger.service, "[\(serviceId)] Voice trigger monitoring started")

        } catch {
            AppLogger.error(AppLogger.service, "[\(serviceId)] Failed to start monitoring: \(error.localizedDescription)")
            transition(to: .error(.wakeWordInitFailed(error.localizedDescription)), context: "startMonitoringFailed")
            throw VoiceTriggerError.wakeWordInitFailed(error.localizedDescription)
        }
    }

    /// Stop voice trigger monitoring
    ///
    /// Stops all monitoring activity and returns to idle state.
    /// Any in-progress capture or transcription is cancelled.
    func stopMonitoring() async {
        AppLogger.info(AppLogger.service, "[\(serviceId)] stopMonitoring() called, state=\(state.description)")

        // Prevent double-stop
        guard state != .idle else {
            AppLogger.debug(AppLogger.service, "[\(serviceId)] Already idle, skipping stopMonitoring")
            return
        }

        // Stop timers
        silenceTimer?.invalidate()
        silenceTimer = nil
        deinitSilenceTimer = nil
        maxDurationTimer?.invalidate()
        maxDurationTimer = nil
        deinitMaxDurationTimer = nil

        // Cancel any pending recovery task to prevent state changes after stop
        recoveryTask?.cancel()
        recoveryTask = nil

        isHandlingTimeout = false

        cancelFluidAudioIdleEviction()

        stopFrameConsumer()

        // Stop services - await to prevent race conditions on restart
        await wakeWordService.shutdown()
        _ = try? await audioService.stopCapture()
        await fluidAudioService.shutdown()

        // Clear state
        currentKeyword = nil
        silenceTimeRemaining = nil
        capturedSamples = []
        audioLevel = 0.0

        // Transition to idle
        transition(to: .idle, context: "stopMonitoring")

        AppLogger.debug(AppLogger.service, "[\(serviceId)] Voice trigger monitoring stopped")
    }

    /// Handle incoming audio samples
    ///
    /// Routes audio data to the appropriate handler based on current state:
    /// - In monitoring mode: Sends to wake word service for keyword detection
    /// - In capturing mode: Accumulates samples for transcription
    ///
    /// Note: This method is already called from a MainActor Task dispatch in the audio callback.
    /// The non-Sendable `AVAudioPCMBuffer` is converted to `[Int16]` on the audio thread before
    /// hopping into MainActor — see the `bufferCallback` closure in `startMonitoring()` and
    /// `.claude/references/concurrency.md` §3.
    ///
    /// - Parameters:
    ///   - samples: Audio samples already extracted from the buffer on the audio thread
    ///   - sampleRate: Native sample rate the buffer arrived at, in Hz
    private var audioBufferCount = 0
    private func handleAudioBuffer(_ frame: IncomingAudioFrame) {
        audioBufferCount += 1
        if audioBufferCount % 100 == 1 {
            AppLogger.trace(AppLogger.service, "[\(serviceId)] handleAudioBuffer called \(audioBufferCount) times, state=\(state.description)")
        }
        switch self.state {
        case .monitoring:
            let energy = normalizedEnergy(of: frame)
            guard energy >= Constants.Audio.talkingThreshold else { return }

            let floatSamples = floatSamplesForWakeWord(from: frame)
            guard !floatSamples.isEmpty else { return }

            if audioBufferCount % 100 == 1 {
                AppLogger.trace(AppLogger.service, "[\(serviceId)] Enqueuing \(floatSamples.count) samples for wake word service")
            }

            frameStreamContinuation?.yield(floatSamples)

        case .capturing:
            accumulateFrame(frame)

        default:
            break
        }
    }

    /// Convert Int16 audio samples to Float samples normalized to [-1.0, 1.0] at 16kHz
    private func convertInt16SamplesToFloat(_ samples: [Int16], sourceRate: Double) -> [Float] {
        let targetSampleRate = Double(Constants.VoiceTrigger.sampleRate)
        var floatSamples = samples.map { Float($0) / 32768.0 }

        if abs(sourceRate - targetSampleRate) > 1.0 {
            floatSamples = resampleToTarget(floatSamples, from: sourceRate, to: targetSampleRate)
        }

        return floatSamples
    }

    /// Normalized RMS energy in 0…1 range for wake-word pre-gating (PRF-11).
    private func normalizedEnergy(of frame: IncomingAudioFrame) -> Double {
        switch frame {
        case .floatSamples(let samples, _):
            guard !samples.isEmpty else { return 0 }
            var sumSquares: Double = 0
            for sample in samples {
                let value = Double(sample)
                sumSquares += value * value
            }
            return sqrt(sumSquares / Double(samples.count))

        case .int16Samples(let samples, _):
            let metrics = AudioBuffer.computeMetrics(samples: samples)
            return metrics.rms / 32768.0
        }
    }

    /// Prepare float samples for sherpa-onnx, preserving native float path when available (PRF-11).
    private func floatSamplesForWakeWord(from frame: IncomingAudioFrame) -> [Float] {
        switch frame {
        case .floatSamples(let samples, let sampleRate):
            let targetSampleRate = Double(Constants.VoiceTrigger.sampleRate)
            if abs(sampleRate - targetSampleRate) > 1.0 {
                return resampleToTarget(samples, from: sampleRate, to: targetSampleRate)
            }
            return samples

        case .int16Samples(let samples, let sampleRate):
            return convertInt16SamplesToFloat(samples, sourceRate: sampleRate)
        }
    }

    /// Resample float audio samples from source rate to target rate using linear interpolation
    ///
    /// This is a simple resampler suitable for real-time wake word detection.
    /// For higher quality (transcription), FluidAudio's AudioConverter is used instead.
    ///
    /// - Parameters:
    ///   - samples: Input float samples normalized to [-1.0, 1.0]
    ///   - sourceRate: Source sample rate in Hz (e.g., 48000)
    ///   - targetRate: Target sample rate in Hz (e.g., 16000)
    /// - Returns: Resampled float samples at target rate
    private func resampleToTarget(_ samples: [Float], from sourceRate: Double, to targetRate: Double) -> [Float] {
        guard !samples.isEmpty, sourceRate > 0, targetRate > 0 else { return [] }

        let ratio = sourceRate / targetRate
        let outputLength = Int(Double(samples.count) / ratio)

        guard outputLength > 0 else { return [] }

        var output = [Float](repeating: 0, count: outputLength)

        for outputIndex in 0..<outputLength {
            let sourcePosition = Double(outputIndex) * ratio
            let sourceIndex = Int(sourcePosition)
            let fraction = Float(sourcePosition - Double(sourceIndex))

            // Linear interpolation between adjacent samples
            let sample1 = samples[sourceIndex]
            let sample2 = sourceIndex + 1 < samples.count ? samples[sourceIndex + 1] : sample1
            output[outputIndex] = sample1 + fraction * (sample2 - sample1)
        }

        return output
    }

    // MARK: - Private Methods

    /// Start the ordered frame consumer that feeds `wakeWordService.processFrame`
    /// sequentially. Must be called after `wakeWordService.initialize` succeeds.
    private func startFrameConsumer() {
        stopFrameConsumer()

        let stream = AsyncStream<[Float]> { continuation in
            self.frameStreamContinuation = continuation
        }

        let wakeWord = wakeWordService
        let capturedServiceId = serviceId
        frameConsumerTask = Task { @MainActor [weak self] in
            for await floatSamples in stream {
                guard let self, !Task.isCancelled else { break }
                if let result = await wakeWord.processFrame(floatSamples) {
                    AppLogger.info(
                        AppLogger.service,
                        "[\(capturedServiceId)] Wake word DETECTED: \(result.detectedKeyword)"
                    )
                    self.handleWakeWordDetected(keyword: result.detectedKeyword)
                }
            }
        }
    }

    /// Tear down the ordered frame consumer and finish the stream.
    private func stopFrameConsumer() {
        frameStreamContinuation?.finish()
        frameStreamContinuation = nil
        frameConsumerTask?.cancel()
        frameConsumerTask = nil
    }

    /// Handle audio level updates from capture service
    private func handleAudioLevel(_ level: Double) {
        audioLevel = level

        // Track audio activity for silence detection (resets silence timer when talking)
        if level >= Constants.Audio.talkingThreshold {
            lastAudioTime = Date()
            // Log during capture to verify silence reset is working
            if case .capturing = state {
                AppLogger.debug(AppLogger.service, "[\(serviceId)] Voice detected during capture - silence timer reset, level=\(String(format: "%.3f", level))")
            }
        }
    }

    /// Handle wake word detection
    private func handleWakeWordDetected(keyword: String) {
        AppLogger.info(AppLogger.service, "[\(serviceId)] Wake word detected: \"\(keyword)\"")

        guard state == .monitoring else {
            AppLogger.warning(AppLogger.service, "[\(serviceId)] Wake word detected but not in monitoring state")
            return
        }

        // Update state - first transition to triggered
        currentKeyword = keyword
        transition(to: .triggered(keyword: keyword), context: "wakeWordDetected")

        // Play feedback if enabled
        if configuration.feedbackSoundEnabled {
            playFeedbackSound()
        }

        // Immediately transition to capturing
        transition(to: .capturing, context: "startCapture")

        // Clear previous samples and start fresh capture
        capturedSamples = []
        lastAudioTime = Date()

        // Start silence detection timer
        startSilenceTimer()

        // Start max duration timer
        startMaxDurationTimer()

        AppLogger.debug(AppLogger.service, "[\(serviceId)] Capture started for keyword: \(keyword)")
    }

    private func accumulateFrame(_ frame: IncomingAudioFrame) {
        switch frame {
        case .floatSamples(let samples, let sampleRate):
            let int16Samples = samples.map { sample in
                let clamped = max(-1.0, min(1.0, sample))
                return Int16(clamped * Float(Int16.max))
            }
            capturedSamples.append(contentsOf: int16Samples)
            capturedSampleRate = sampleRate

        case .int16Samples(let samples, let sampleRate):
            capturedSamples.append(contentsOf: samples)
            capturedSampleRate = sampleRate
        }

        AppLogger.trace(
            AppLogger.service,
            "[\(serviceId)] Accumulated frame, total=\(capturedSamples.count)"
        )
    }

    /// Start silence detection timer
    private func startSilenceTimer() {
        silenceTimer?.invalidate()

        // Update silence time remaining every 0.1 seconds
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkSilence()
            }
        }
        // Explicitly add to main run loop to ensure timer fires correctly
        RunLoop.main.add(timer, forMode: .common)
        silenceTimer = timer
        deinitSilenceTimer = timer

        AppLogger.debug(
            AppLogger.service,
            "[\(serviceId)] Silence timer started (threshold: \(configuration.silenceThresholdSeconds)s)"
        )
    }

    /// Check for silence timeout
    private var silenceLogCounter = 0
    private func checkSilence() {
        guard case .capturing = state else { return }
        guard let lastAudio = lastAudioTime else { return }

        let silenceDuration = Date().timeIntervalSince(lastAudio)
        let threshold = configuration.silenceThresholdSeconds

        // Update remaining time for UI
        silenceTimeRemaining = max(0, threshold - silenceDuration)

        // Log every second to show silence countdown
        silenceLogCounter += 1
        if silenceLogCounter % 10 == 0 {
            AppLogger.debug(AppLogger.service, "[\(serviceId)] Silence check: \(String(format: "%.1f", silenceDuration))s / \(String(format: "%.0f", threshold))s threshold")
        }

        if silenceDuration >= threshold {
            guard !isHandlingTimeout else { return }
            isHandlingTimeout = true
            silenceLogCounter = 0
            AppLogger.info(
                AppLogger.service,
                "[\(serviceId)] Silence threshold reached (\(String(format: "%.1f", silenceDuration))s) - transcribing"
            )

            // Invalidate timers synchronously before the async handler so
            // further silence ticks cannot enqueue another timeout task.
            silenceTimer?.invalidate()
            silenceTimer = nil
            deinitSilenceTimer = nil
            maxDurationTimer?.invalidate()
            maxDurationTimer = nil
            deinitMaxDurationTimer = nil

            Task { @MainActor [weak self] in
                defer { self?.isHandlingTimeout = false }
                await self?.handleSilenceTimeout()
            }
        }
    }

    /// Handle silence timeout - stop capture and transcribe
    private func handleSilenceTimeout() async {
        // Guard against being called after stopMonitoring() or in wrong state
        guard case .capturing = state else {
            AppLogger.debug(AppLogger.service, "[\(serviceId)] handleSilenceTimeout ignored - not in capturing state")
            return
        }

        AppLogger.info(AppLogger.service, "[\(serviceId)] handleSilenceTimeout()")

        silenceTimeRemaining = nil

        // Proceed to transcription if we have audio
        if !capturedSamples.isEmpty {
            await transcribeAndInsert()
        } else {
            AppLogger.warning(AppLogger.service, "[\(serviceId)] No audio captured, returning to monitoring")
            currentKeyword = nil
            transition(to: .monitoring, context: "noAudioCaptured")
        }
    }

    /// Start max duration timer
    private func startMaxDurationTimer() {
        maxDurationTimer?.invalidate()

        let timer = Timer.scheduledTimer(withTimeInterval: configuration.maxRecordingDuration, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard !self.isHandlingTimeout else { return }
                self.isHandlingTimeout = true
                AppLogger.info(AppLogger.service, "[\(self.serviceId)] Max recording duration reached")

                self.silenceTimer?.invalidate()
                self.silenceTimer = nil
                self.deinitSilenceTimer = nil
                self.maxDurationTimer?.invalidate()
                self.maxDurationTimer = nil
                self.deinitMaxDurationTimer = nil

                defer { self.isHandlingTimeout = false }
                await self.handleSilenceTimeout()
            }
        }
        // Explicitly add to main run loop to ensure timer fires correctly
        RunLoop.main.add(timer, forMode: .common)
        maxDurationTimer = timer
        deinitMaxDurationTimer = timer

        AppLogger.debug(
            AppLogger.service,
            "[\(serviceId)] Max duration timer started (\(configuration.maxRecordingDuration)s)"
        )
    }

    /// Transcribe captured audio and insert text
    private func transcribeAndInsert() async {
        AppLogger.info(
            AppLogger.service,
            "[\(serviceId)] transcribeAndInsert() - \(capturedSamples.count) samples at \(Int(capturedSampleRate))Hz"
        )

        cancelFluidAudioIdleEviction()
        transition(to: .transcribing, context: "transcribeAndInsert")

        do {
            let settings = settingsService.load()
            try await fluidAudioService.initialize(language: settings.language.defaultLanguage)

            let result = try await fluidAudioService.transcribe(
                samples: capturedSamples,
                sampleRate: capturedSampleRate
            )

            AppLogger.info(
                AppLogger.service,
                "[\(serviceId)] Transcription complete: \"\(result.text.prefix(50))...\" (confidence: \(result.confidence))"
            )

            lastTranscribedText = result.text

            let trimmedText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedText.isEmpty else {
                AppLogger.warning(AppLogger.service, "[\(serviceId)] Empty transcription, returning to monitoring")
                currentKeyword = nil
                capturedSamples = []
                transition(to: .monitoring, context: "emptyTranscription")
                scheduleFluidAudioIdleEviction()
                return
            }

            transition(to: .inserting, context: "insertText")

            let insertResult = await textInsertionService.insertTextWithFallback(trimmedText)

            switch insertResult {
            case .insertedViaAccessibility:
                AppLogger.info(AppLogger.service, "[\(serviceId)] Text inserted successfully")

            case .copiedToClipboardOnly(let reason):
                AppLogger.info(AppLogger.service, "[\(serviceId)] Text copied to clipboard: \(String(describing: reason))")

            case .requiresAccessibilityPermission:
                AppLogger.warning(AppLogger.service, "[\(serviceId)] Accessibility permission required")
            }

            currentKeyword = nil
            capturedSamples = []
            transition(to: .monitoring, context: "complete")
            scheduleFluidAudioIdleEviction()

        } catch {
            AppLogger.error(AppLogger.service, "[\(serviceId)] Transcription/insertion failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            transition(to: .error(.transcriptionFailed(error.localizedDescription)), context: "transcribeFailed")

            recoveryTask?.cancel()
            recoveryTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                } catch {
                    return
                }
                guard let self, case .error = self.state else { return }
                AppLogger.debug(AppLogger.service, "[\(self.serviceId)] Recovering from error to monitoring state")
                self.transition(to: .monitoring, context: "errorRecovery")
                self.errorMessage = nil
                self.recoveryTask = nil
                self.scheduleFluidAudioIdleEviction()
            }
        }
    }

    /// Push discrete state transitions to observers (PRF-10).
    private func transition(to newState: VoiceTriggerState, context: String) {
        let previous = state
        guard previous != newState else { return }
        AppLogger.stateChange(AppLogger.service, from: previous, to: newState, context: context)
        state = newState
        onStateChange?(previous, newState)
    }

    /// Release FluidAudio after idle period without transcription (PRF-8).
    private func scheduleFluidAudioIdleEviction() {
        fluidAudioIdleEvictionTask?.cancel()
        let delay = Constants.VoiceTrigger.fluidAudioIdleEvictionSeconds
        fluidAudioIdleEvictionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            await self.fluidAudioService.shutdown()
            AppLogger.debug(
                AppLogger.service,
                "[\(self.serviceId)] FluidAudio idle-evicted after \(delay)s"
            )
        }
    }

    private func cancelFluidAudioIdleEviction() {
        fluidAudioIdleEvictionTask?.cancel()
        fluidAudioIdleEvictionTask = nil
    }

    /// Play feedback sound when wake word is detected
    private func playFeedbackSound() {
        // Use system sound for minimal latency
        // NSSound.beep() is simple but works; could be enhanced with custom sound
        AppLogger.trace(AppLogger.service, "[\(serviceId)] Playing feedback sound")
        NSSound.beep()
    }
}
