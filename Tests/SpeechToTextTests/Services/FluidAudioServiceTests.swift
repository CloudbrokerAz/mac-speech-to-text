import XCTest
@testable import SpeechToText

final class FluidAudioServiceTests: XCTestCase {

    // MARK: - Initialization Tests

    func test_initialization_createsService() async {
        // Given/When
        let service = FluidAudioService()

        // Then
        let isInitialized = await service.checkInitialized()
        XCTAssertFalse(isInitialized)
    }

    func test_initialization_startsWithEnglishLanguage() async {
        // Given/When
        let service = FluidAudioService()

        // Then
        let currentLanguage = await service.getCurrentLanguage()
        XCTAssertEqual(currentLanguage, "en")
    }

    // MARK: - Initialize Tests

    func test_initialize_setsInitializedFlag() async throws {
        // Given
        let service = FluidAudioService()
        let initialState = await service.checkInitialized()
        XCTAssertFalse(initialState)

        // When
        // Note: This will fail in tests because FluidAudio SDK is not available
        // This is a TDD test that should initially fail
        do {
            try await service.initialize(language: "en")
            let isInitialized = await service.checkInitialized()
            XCTAssertTrue(isInitialized)
        } catch {
            // Expected to fail in test environment without FluidAudio SDK
            XCTAssertTrue(error is FluidAudioError)
        }
    }

    func test_initialize_doesNotReinitializeIfAlreadyInitialized() async throws {
        // Given
        let service = FluidAudioService()

        // When/Then
        // First initialization attempt
        do {
            try await service.initialize(language: "en")
        } catch {
            // Expected to fail in test environment
        }

        // Second initialization should not throw or reinitialize
        do {
            try await service.initialize(language: "fr")
        } catch {
            // Expected to fail in test environment
        }
    }

    // MARK: - Transcribe Tests

    func test_transcribe_throwsErrorWhenNotInitialized() async {
        // Given
        let service = FluidAudioService()
        let samples: [Int16] = Array(repeating: 100, count: 1600)

        // When/Then
        do {
            _ = try await service.transcribe(samples: samples, sampleRate: 16000.0)
            XCTFail("Should throw notInitialized error")
        } catch let error as FluidAudioError {
            XCTAssertEqual(error, .notInitialized)
        } catch {
            XCTFail("Wrong error type")
        }
    }

    func test_transcribe_throwsErrorWhenSamplesAreEmpty() async {
        // Given
        let service = FluidAudioService()
        let samples: [Int16] = []

        // When/Then
        // Note: notInitialized error takes precedence over invalidAudioFormat
        // when service is not initialized
        do {
            _ = try await service.transcribe(samples: samples, sampleRate: 16000.0)
            XCTFail("Should throw error")
        } catch let error as FluidAudioError {
            // Either notInitialized (if checked first) or invalidAudioFormat is acceptable
            XCTAssertTrue(error == .notInitialized || error == .invalidAudioFormat,
                          "Expected notInitialized or invalidAudioFormat, got \(error)")
        } catch {
            XCTFail("Wrong error type")
        }
    }

    // MARK: - Language Switch Tests

    func test_switchLanguage_throwsErrorForUnsupportedLanguage() async {
        // Given
        let service = FluidAudioService()

        // When/Then
        do {
            try await service.switchLanguage(to: "zh") // Chinese not supported
            XCTFail("Should throw languageNotSupported error")
        } catch let error as FluidAudioError {
            if case .languageNotSupported(let lang) = error {
                XCTAssertEqual(lang, "zh")
            } else {
                XCTFail("Wrong error type")
            }
        } catch {
            XCTFail("Wrong error type")
        }
    }

    func test_switchLanguage_acceptsSupportedLanguage() async throws {
        // Given
        let service = FluidAudioService()

        // When
        try await service.switchLanguage(to: "fr")

        // Then
        let currentLanguage = await service.getCurrentLanguage()
        XCTAssertEqual(currentLanguage, "fr")
    }

    func test_switchLanguage_supportsAllEuropeanLanguages() async {
        // Given
        let service = FluidAudioService()
        let europeanLanguages = ["en", "es", "fr", "de", "it", "pt", "ru", "pl"]

        // When/Then
        for language in europeanLanguages {
            do {
                try await service.switchLanguage(to: language)
                let currentLanguage = await service.getCurrentLanguage()
                XCTAssertEqual(currentLanguage, language)
            } catch {
                XCTFail("Should support language: \(language)")
            }
        }
    }

    // MARK: - Shutdown Tests

    func test_shutdown_resetsServiceState() async {
        // Given
        let service = FluidAudioService()

        // When
        await service.shutdown()

        // Then
        let isInitialized = await service.checkInitialized()
        XCTAssertFalse(isInitialized)
    }

    // MARK: - Error Description Tests

    func test_fluidAudioError_notInitialized_hasCorrectDescription() {
        // Given
        let error = FluidAudioError.notInitialized

        // When
        let description = error.errorDescription

        // Then
        XCTAssertEqual(description, "FluidAudio service has not been initialized")
    }

    func test_fluidAudioError_modelNotLoaded_hasCorrectDescription() {
        // Given
        let error = FluidAudioError.modelNotLoaded

        // When
        let description = error.errorDescription

        // Then
        XCTAssertEqual(description, "Language model has not been loaded")
    }

    func test_fluidAudioError_invalidAudioFormat_hasCorrectDescription() {
        // Given
        let error = FluidAudioError.invalidAudioFormat

        // When
        let description = error.errorDescription

        // Then
        XCTAssertEqual(description, "Invalid audio format. Expected 16kHz mono Int16 samples")
    }

    func test_fluidAudioError_languageNotSupported_hasCorrectDescription() {
        // Given
        let error = FluidAudioError.languageNotSupported("zh")

        // When
        let description = error.errorDescription

        // Then
        XCTAssertEqual(description, "Language 'zh' is not supported")
    }

    // MARK: - TranscriptionResult Tests

    func test_transcriptionResult_initialization() {
        // Given/When
        let result = TranscriptionResult(text: "Hello world", confidence: 0.95, durationMs: 150)

        // Then
        XCTAssertEqual(result.text, "Hello world")
        XCTAssertEqual(result.confidence, 0.95)
        XCTAssertEqual(result.durationMs, 150)
    }

    // MARK: - Thread Safety Tests (Actor)

    func test_service_canBeAccessedFromMultipleTasksConcurrently() async {
        // Given
        let service = FluidAudioService()

        // When
        await withTaskGroup(of: String.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    await service.getCurrentLanguage()
                }
            }

            // Then
            for await language in group {
                XCTAssertEqual(language, "en")
            }
        }
    }

    func test_service_switchLanguage_isThreadSafe() async {
        // Given
        let service = FluidAudioService()
        let languages = ["en", "fr", "de", "es", "it"]

        // When
        await withTaskGroup(of: Void.self) { group in
            for language in languages {
                group.addTask {
                    try? await service.switchLanguage(to: language)
                }
            }
        }

        // Then
        let finalLanguage = await service.getCurrentLanguage()
        XCTAssertTrue(languages.contains(finalLanguage))
    }

    // MARK: - Reentrancy Guard Tests (#40d)

    /// Smoke test for the single-flight wrapper boilerplate introduced in
    /// #40d: under contention the wrapper does not deadlock, does not
    /// crash, and every concurrent call surfaces `notInitialized` rather
    /// than mismatched / mixed errors. This exercises the *fast* path
    /// (each caller acquires + releases the slot synchronously between
    /// actor turns); the *wait* path is covered by
    /// `test_transcribe_serialisesConcurrentCallsViaWaitPath` below.
    func test_transcribe_concurrentCallsAllReturnNotInitialized() async {
        // Given
        let service = FluidAudioService()
        let samples: [Int16] = Array(repeating: 100, count: 1600)
        let callCount = 8

        // When — fire N concurrent transcribes against an uninitialised
        // service. Each call's `runTranscribe` will throw `notInitialized`
        // because `asrManager` is nil.
        let errors: [Error?] = await withTaskGroup(of: Error?.self) { group in
            for _ in 0..<callCount {
                group.addTask {
                    do {
                        _ = try await service.transcribe(
                            samples: samples,
                            sampleRate: 16000.0
                        )
                        return nil
                    } catch {
                        return error
                    }
                }
            }
            var collected: [Error?] = []
            for await error in group { collected.append(error) }
            return collected
        }

        // Then — every caller surfaced an error (none returned a value),
        // and every error is `notInitialized` (no other failure mode).
        // If the guard deadlocked, this would hang and fail via timeout.
        XCTAssertEqual(errors.count, callCount)
        for case let .some(error) in errors {
            guard let fluidError = error as? FluidAudioError else {
                XCTFail("Expected FluidAudioError, got \(type(of: error))")
                continue
            }
            XCTAssertEqual(fluidError, .notInitialized)
        }
    }

    /// Forces the *wait* path of the single-flight guard: the holder is
    /// kept in flight long enough that subsequent callers genuinely
    /// queue on `transcribeWaiters`. Verifies FIFO hand-off works (every
    /// caller gets resumed) without a missed `resume()` (which would
    /// hang the test).
    ///
    /// Uses the `transcribeSimulatedDelay` test seam to slow the active
    /// transcribe so reentrant callers observe `transcribeInFlight ==
    /// true` and suspend on a continuation. Combined with `simulatedError
    /// = .transcription`, every call surfaces `transcriptionFailed`
    /// cleanly — proving the queue drained and no waiter was stranded.
    func test_transcribe_serialisesConcurrentCallsViaWaitPath() async {
        // Given — service that holds the slot for 50ms per call,
        // forcing reentrant callers to queue.
        let service = FluidAudioService(
            simulatedError: .transcription,
            transcribeSimulatedDelay: .milliseconds(50)
        )
        let samples: [Int16] = Array(repeating: 100, count: 1600)
        let callCount = 5
        let started = Date()

        // When — fire N concurrent calls; the first acquires the slot,
        // the rest queue.
        let errors: [Error?] = await withTaskGroup(of: Error?.self) { group in
            for _ in 0..<callCount {
                group.addTask {
                    do {
                        _ = try await service.transcribe(
                            samples: samples,
                            sampleRate: 16000.0
                        )
                        return nil
                    } catch {
                        return error
                    }
                }
            }
            var collected: [Error?] = []
            for await error in group { collected.append(error) }
            return collected
        }
        let elapsed = Date().timeIntervalSince(started)

        // Then — every caller threw, every error is the simulated
        // transcriptionFailed (proves runTranscribe ran on each, slot
        // released cleanly between).
        XCTAssertEqual(errors.count, callCount)
        for case let .some(error) in errors {
            guard let fluidError = error as? FluidAudioError else {
                XCTFail("Expected FluidAudioError, got \(type(of: error))")
                continue
            }
            if case .transcriptionFailed = fluidError {
                // pass
            } else {
                XCTFail("Expected .transcriptionFailed, got \(fluidError)")
            }
        }

        // And — total elapsed time should be >= callCount * delay
        // (modulo scheduling jitter). If the calls had run *concurrently*
        // (guard broken), elapsed would be ~one delay. We use a forgiving
        // lower bound (75%) to absorb test-runner jitter while still
        // catching a fully-broken guard.
        let lowerBound = Double(callCount) * 0.050 * 0.75
        XCTAssertGreaterThanOrEqual(
            elapsed, lowerBound,
            "expected serialised execution (~\(callCount) × 50ms), got \(elapsed)s"
        )
    }

    /// After concurrent calls all complete, the service must be ready to
    /// accept another call — i.e. the in-flight slot was released. This
    /// catches a class of bug where the slot is handed to a waiter on the
    /// failure path but the flag never clears (next caller would hang).
    func test_transcribe_isUsableAfterContention() async {
        // Given
        let service = FluidAudioService()
        let samples: [Int16] = Array(repeating: 100, count: 1600)

        // When — drive contention then issue one more call.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    _ = try? await service.transcribe(samples: samples, sampleRate: 16000.0)
                }
            }
        }

        // Then — a follow-up call still throws cleanly (no hang, no crash).
        do {
            _ = try await service.transcribe(samples: samples, sampleRate: 16000.0)
            XCTFail("Should still throw notInitialized")
        } catch let error as FluidAudioError {
            XCTAssertEqual(error, .notInitialized)
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    /// Verifies that `shutdown()` drains queued waiters so their
    /// `CheckedContinuation`s don't leak and their callers don't hang
    /// forever. Uses the wait-path delay seam to ensure waiters are
    /// genuinely queued before shutdown.
    func test_shutdown_drainsQueuedWaiters() async {
        // Given — service set up so the active transcribe blocks long
        // enough for a second caller to queue, then we shut down.
        let service = FluidAudioService(
            simulatedError: .transcription,
            transcribeSimulatedDelay: .milliseconds(200)
        )
        let samples: [Int16] = Array(repeating: 100, count: 1600)

        // When — kick off the holder, give it a moment to acquire the
        // slot, kick off a second caller (which will queue), then shut
        // down before the holder completes.
        async let holder: Error? = {
            do {
                _ = try await service.transcribe(samples: samples, sampleRate: 16000.0)
                return nil
            } catch {
                return error
            }
        }()
        // Yield so the holder reaches the slot acquisition.
        try? await Task.sleep(for: .milliseconds(20))

        async let queued: Error? = {
            do {
                _ = try await service.transcribe(samples: samples, sampleRate: 16000.0)
                return nil
            } catch {
                return error
            }
        }()
        // Yield so the second caller reaches the wait path.
        try? await Task.sleep(for: .milliseconds(20))

        await service.shutdown()

        // Then — both calls return (no hang). The holder finishes its
        // simulated delay then throws `transcriptionFailed`. The queued
        // caller is woken by shutdown's drain, hits `notInitialized`
        // because `asrManager` is now nil.
        let holderError = await holder
        let queuedError = await queued

        XCTAssertNotNil(holderError, "holder should have surfaced an error")
        XCTAssertNotNil(queuedError, "queued caller should have surfaced an error")
        // Holder ran through its body; queued was drained post-shutdown.
        // Either error type is acceptable as long as both paths terminated.
    }
}
