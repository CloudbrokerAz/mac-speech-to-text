import Foundation
import Testing
@testable import SpeechToText

/// Tests for the `MockLLMProvider` test fake. These exist so the fake
/// itself is covered — its behaviour is load-bearing for every future
/// consumer test (`ClinicalNotesProcessor` #5 being the first).
@Suite("MockLLMProvider", .tags(.fast))
struct MockLLMProviderTests {
    // MARK: - Fixed response

    @Test("Fixed-response mode returns the same string for every call")
    func fixedResponse_isStableAcrossCalls() async throws {
        let provider = MockLLMProvider(response: "hello")

        let first = try await provider.generate(
            prompt: "a",
            options: LLMOptions()
        )
        let second = try await provider.generate(
            prompt: "b",
            options: LLMOptions()
        )

        #expect(first == "hello")
        #expect(second == "hello")
        #expect(await provider.callCount() == 2)
    }

    @Test("Default init returns the empty string")
    func defaultInit_returnsEmptyString() async throws {
        let provider = MockLLMProvider()

        let result = try await provider.generate(
            prompt: "anything",
            options: LLMOptions()
        )

        #expect(result.isEmpty)
    }

    // MARK: - Queued responses

    @Test("Queued responses pop front-first")
    func queuedResponses_popInOrder() async throws {
        let provider = MockLLMProvider(responses: ["first", "second", "third"])

        let one = try await provider.generate(prompt: "p", options: LLMOptions())
        let two = try await provider.generate(prompt: "p", options: LLMOptions())
        let three = try await provider.generate(prompt: "p", options: LLMOptions())

        #expect(one == "first")
        #expect(two == "second")
        #expect(three == "third")
    }

    @Test("Queued responses throw responseQueueExhausted after drain")
    func queuedResponses_exhaustionThrows() async throws {
        let provider = MockLLMProvider(responses: ["only"])

        _ = try await provider.generate(prompt: "p", options: LLMOptions())

        await #expect(throws: MockLLMProviderError.responseQueueExhausted) {
            _ = try await provider.generate(prompt: "p", options: LLMOptions())
        }
    }

    @Test("Empty queue throws on the first call")
    func queuedResponses_emptyFromStart_throws() async throws {
        let provider = MockLLMProvider(responses: [])

        await #expect(throws: MockLLMProviderError.responseQueueExhausted) {
            _ = try await provider.generate(prompt: "p", options: LLMOptions())
        }
    }

    // MARK: - Error injection

    @Test("Error mode throws the injected error on every call")
    func errorMode_throws() async throws {
        let provider = MockLLMProvider(error: SampleError.boom)

        await #expect(throws: SampleError.boom) {
            _ = try await provider.generate(prompt: "p", options: LLMOptions())
        }
        await #expect(throws: SampleError.boom) {
            _ = try await provider.generate(prompt: "p", options: LLMOptions())
        }

        #expect(await provider.callCount() == 2)
    }

    // MARK: - Call log

    @Test("Call log captures prompt and options verbatim")
    func callLog_capturesPromptAndOptions() async throws {
        let provider = MockLLMProvider(response: "ok")
        let options = LLMOptions(temperature: 0.3, maxTokens: 512, seed: 7)

        _ = try await provider.generate(prompt: "transcript", options: options)

        let last = await provider.lastCall()
        #expect(last?.prompt == "transcript")
        #expect(last?.options == options)
    }

    @Test("reset() clears the call log but preserves behaviour")
    func reset_clearsCallLog() async throws {
        let provider = MockLLMProvider(response: "x")

        _ = try await provider.generate(prompt: "a", options: LLMOptions())
        #expect(await provider.callCount() == 1)

        await provider.reset()

        #expect(await provider.callCount() == 0)
        // Behaviour still fires after reset.
        let after = try await provider.generate(prompt: "b", options: LLMOptions())
        #expect(after == "x")
    }

    @Test("setBehavior swaps mode mid-test")
    func setBehavior_swapsMode() async throws {
        let provider = MockLLMProvider(response: "first-mode")

        let one = try await provider.generate(prompt: "p", options: LLMOptions())
        #expect(one == "first-mode")

        await provider.setBehavior(.queuedResponses(["after-swap"]))
        let two = try await provider.generate(prompt: "p", options: LLMOptions())
        #expect(two == "after-swap")
    }

    // MARK: - Streaming

    @Test("generateStream yields the fixed response then finishes")
    func stream_fixedResponse() async throws {
        let provider = MockLLMProvider(response: "streamed")

        var collected: [String] = []
        for try await chunk in provider.generateStream(
            prompt: "p",
            options: LLMOptions()
        ) {
            collected.append(chunk)
        }

        #expect(collected == ["streamed"])
    }

    @Test("generateStream finishes with the injected error")
    func stream_errorModePropagates() async throws {
        let provider = MockLLMProvider(error: SampleError.boom)

        await #expect(throws: SampleError.boom) {
            for try await _ in provider.generateStream(
                prompt: "p",
                options: LLMOptions()
            ) {
                // Drain until the stream errors.
            }
        }
    }

    @Test("generateStream cancellation terminates the underlying task")
    func stream_cancellation_terminates() async throws {
        // The protocol contract says cancelling the awaiting task cancels
        // the underlying generation. We can't observe "cancel mid-token"
        // on this fast fake, but we can prove the stream terminates
        // cleanly when a consumer drops out after the first chunk
        // (exercising the `onTermination` → `task.cancel()` wiring).
        let provider = MockLLMProvider(response: "done")

        var seen: [String] = []
        for try await chunk in provider.generateStream(
            prompt: "p",
            options: LLMOptions()
        ) {
            seen.append(chunk)
            break
        }

        #expect(seen == ["done"])
        // One generate call, regardless of whether we drained the stream.
        #expect(await provider.callCount() == 1)
    }
}

// MARK: - Test fixtures

private enum SampleError: Error, Equatable, Sendable {
    case boom
}
