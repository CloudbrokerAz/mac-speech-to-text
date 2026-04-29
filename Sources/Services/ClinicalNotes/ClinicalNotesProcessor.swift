import Foundation

/// Orchestrates the transcript → `StructuredNotes` pipeline.
///
/// **Issue #5.** Wires three previously-landed pieces:
/// - `ClinicalNotesPromptBuilder` (#4) for prompt assembly + JSON
///   schema validation,
/// - `LLMProvider` (#3 protocol slice) for local inference,
/// - `ManipulationsRepository` (#6) for the taxonomy the prompt
///   enumerates and the response maps back to.
///
/// The concrete `LLMProvider` will be `MLXGemmaProvider` once the
/// MLX-Swift concrete implementation lands (same ticket, follow-up
/// PR). Tests exercise this actor against `MockLLMProvider`.
///
/// ### Retry-once contract
/// On a `SchemaError` from the first response, the processor issues a
/// second `generate` call with a short "fix the JSON" prompt that
/// quotes the invalid output and restates the schema requirement. The
/// quote is load-bearing: deterministic defaults (`temperature: 0`,
/// fixed `seed`) would otherwise reproduce the same invalid output,
/// making naive retries pointless. Including the prior bad response in
/// the prompt perturbs the context enough for the model to attempt a
/// correction.
///
/// ### Fallback contract
/// Any path that doesn't yield a valid `StructuredNotes` resolves to
/// `.rawTranscriptFallback(reason:)` so the ReviewScreen (#13) can
/// surface the raw transcript and the practitioner's work is never
/// lost. The `reason` is a structural sentinel — **never** a PHI-
/// bearing error message. See `.claude/references/phi-handling.md`.
///
/// ### PHI
/// `transcript`, the prompt derived from it, and the LLM response all
/// contain patient data. They flow through this actor in-memory only
/// and are never logged or persisted. Error messages from the LLM
/// provider can contain input fragments; the processor therefore
/// refuses to interpolate a caught error's text into the fallback
/// reason — only the structural tag `"llm_error"` is returned.
actor ClinicalNotesProcessor {
    /// Result of a single `process(transcript:)` call.
    enum Outcome: Sendable, Equatable {
        /// A schema-valid SOAP note was produced (possibly after one
        /// retry). The payload is ready for `SessionStore.setDraftNotes`.
        case success(StructuredNotes)
        /// The pipeline could not produce a valid note. The caller
        /// should render the raw transcript and let the practitioner
        /// compose the note manually. `reason` is a structural sentinel
        /// for telemetry / UI branching — never PHI.
        case rawTranscriptFallback(reason: String)
    }

    /// Structural sentinel emitted when any `LLMProvider.generate` call
    /// throws. Deliberately opaque — provider error descriptions can
    /// quote input tokens, so we discard the caught error's text.
    static let reasonLLMError = "llm_error"

    /// Structural sentinel emitted when both the first and the retry
    /// responses fail schema validation (excluding the all-SOAP-empty
    /// shape — that emits the more specific
    /// `reasonAllSOAPEmptyAfterRetry` so audit logs can distinguish
    /// "model produced JSON we couldn't parse" from "model produced
    /// JSON whose SOAP sections were all empty").
    static let reasonInvalidJSONAfterRetry = "invalid_json_after_retry"

    /// Structural sentinel emitted when both attempts produced JSON
    /// whose four SOAP sections were all empty / whitespace-only —
    /// the failure mode bug #100 fixes. Treated as a `.fallback` UX so
    /// the doctor sees a banner + raw-transcript affordance instead
    /// of staring at silently-empty editors.
    static let reasonAllSOAPEmptyAfterRetry = "all_soap_empty_after_retry"

    /// Structural sentinel emitted by `AppState` (NOT by the processor
    /// itself) when the LLM model failed to download or warm up before
    /// inference could start. Co-located here so every fallback reason
    /// the ReviewScreen surfaces lives in a single namespace.
    static let reasonModelUnavailable = "model_unavailable"

    /// Structural sentinel emitted by `ReviewViewModel.loadState` (NOT
    /// by the processor) when the active `ClinicalSession` was cleared
    /// while the Review window was still on screen — typically the
    /// `SessionStore.checkIdleTimeout()` race. Surfacing this as
    /// `.fallback` rather than defaulting to `.ready` is what stops
    /// idle-timeout from masquerading as a successful steady state
    /// (silent-failure-hunter H3 on the bug #100 PR).
    static let reasonSessionExpired = "session_expired"

    // MARK: - Dependencies

    private let provider: any LLMProvider
    private let promptBuilder: ClinicalNotesPromptBuilder
    private let manipulations: ManipulationsRepository
    private let options: LLMOptions

    init(
        provider: any LLMProvider,
        promptBuilder: ClinicalNotesPromptBuilder,
        manipulations: ManipulationsRepository,
        options: LLMOptions = LLMOptions()
    ) {
        self.provider = provider
        self.promptBuilder = promptBuilder
        self.manipulations = manipulations
        self.options = options
    }

    // MARK: - Pipeline

    /// Drive a transcript through the LLM and parse the response.
    ///
    /// Never throws. All failure modes resolve to
    /// `.rawTranscriptFallback(reason:)`.
    func process(transcript: String) async -> Outcome {
        let initialPrompt = promptBuilder.buildPrompt(transcript: transcript)

        let firstResponse: String
        do {
            firstResponse = try await provider.generate(
                prompt: initialPrompt,
                options: options
            )
        } catch {
            logLLMError(error, attempt: 1)
            return .rawTranscriptFallback(reason: Self.reasonLLMError)
        }

        switch promptBuilder.validate(json: firstResponse) {
        case .success(let draft):
            return .success(map(draft))
        case .failure(let schemaError):
            // Record the case tag only — structural, not PHI. See
            // `.claude/references/phi-handling.md`; SchemaError
            // payloads are keyPaths + case names + numeric scores only.
            logSchemaError(schemaError, attempt: 1)
        }

        let retryPrompt = buildRetryPrompt(
            originalPrompt: initialPrompt,
            badResponse: firstResponse
        )

        let secondResponse: String
        do {
            secondResponse = try await provider.generate(
                prompt: retryPrompt,
                options: options
            )
        } catch {
            logLLMError(error, attempt: 2)
            return .rawTranscriptFallback(reason: Self.reasonLLMError)
        }

        switch promptBuilder.validate(json: secondResponse) {
        case .success(let draft):
            return .success(map(draft))
        case .failure(let schemaError):
            logSchemaError(schemaError, attempt: 2)
            // Differentiate the all-empty-SOAP failure mode (bug #100)
            // from generic schema rejection so the audit log + future
            // analytics can attribute "model produced empty JSON twice"
            // separately from "model produced unparseable JSON twice".
            // The user-visible UX is the same fallback banner either way.
            let reason: String = (schemaError == .allSOAPSectionsEmpty)
                ? Self.reasonAllSOAPEmptyAfterRetry
                : Self.reasonInvalidJSONAfterRetry
            return .rawTranscriptFallback(reason: reason)
        }
    }

    // MARK: - Logging (structural only — no PHI)

    /// Record the Swift type name of a caught LLM error. `type(of:)`
    /// is the *class* of error (e.g. `URLError`, `MLXError`), never the
    /// `localizedDescription`, which can quote input tokens.
    private nonisolated func logLLMError(_ error: any Error, attempt: Int) {
        let kind = String(describing: type(of: error))
        AppLogger.service.error(
            "ClinicalNotesProcessor: llm_error attempt=\(attempt, privacy: .public) kind=\(kind, privacy: .public)"
        )
    }

    /// Record the SchemaError case tag. `String(describing:)` on a
    /// `SchemaError` prints the case and its structural payload
    /// (keyPaths, numeric scores) — deliberately designed to be
    /// PHI-safe per #4.
    private nonisolated func logSchemaError(_ error: SchemaError, attempt: Int) {
        AppLogger.service.warning(
            "ClinicalNotesProcessor: schema_invalid attempt=\(attempt, privacy: .public) kind=\(String(describing: error), privacy: .public)"
        )
    }

    // MARK: - Retry prompt

    /// Build the second-attempt prompt. Re-sending the original prompt
    /// against a deterministic provider would reproduce the same
    /// invalid output; quoting the bad response and restating the
    /// requirement perturbs the model enough to attempt a correction.
    private nonisolated func buildRetryPrompt(
        originalPrompt: String,
        badResponse: String
    ) -> String {
        """
        \(originalPrompt)

        Your previous response could not be parsed as a JSON object
        matching the schema above:

        ---
        \(badResponse)
        ---

        Return ONLY the JSON object. No Markdown code fences, no
        commentary before or after the object, no prose. Keep the same
        content; correct the structural error.
        """
    }

    // MARK: - Draft → StructuredNotes mapping

    /// Resolve a `RawLLMDraft` to a `StructuredNotes`. SOAP strings
    /// pass through verbatim; `manipulations[].name` is matched back
    /// to a taxonomy id (see `resolveManipulationID`); unmatchable
    /// names are silently dropped so the practitioner re-adds them
    /// from the ReviewScreen checklist. Order is preserved; duplicate
    /// ids are removed.
    private nonisolated func map(_ draft: RawLLMDraft) -> StructuredNotes {
        var seen: Set<String> = []
        var ids: [String] = []
        for suggested in draft.manipulations {
            guard let resolved = resolveManipulationID(for: suggested.name) else {
                continue
            }
            guard seen.insert(resolved).inserted else { continue }
            ids.append(resolved)
        }

        return StructuredNotes(
            subjective: draft.subjective,
            objective: draft.objective,
            assessment: draft.assessment,
            plan: draft.plan,
            selectedManipulationIDs: ids,
            excluded: draft.excludedContent
        )
    }

    /// Match an LLM-returned manipulation `name` back to a taxonomy id.
    ///
    /// Permissive: the prompt enumerates each manipulation as
    /// `"- id: <id>, name: <display>"`, so the model can legitimately
    /// emit either form. Matching is case-insensitive after trimming
    /// surrounding whitespace. Id match wins if both happen to apply.
    /// Returns `nil` if neither form matches — the unmatchable entry
    /// is then dropped by `map`.
    private nonisolated func resolveManipulationID(
        for name: String
    ) -> String? {
        let key = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !key.isEmpty else { return nil }

        // Single pass; id match wins if it appears anywhere in the
        // list. Remember the first displayName match as a fallback.
        var nameMatch: String?
        for manipulation in manipulations.all {
            if manipulation.id.lowercased() == key {
                return manipulation.id
            }
            if nameMatch == nil, manipulation.displayName.lowercased() == key {
                nameMatch = manipulation.id
            }
        }
        return nameMatch
    }
}
