import Foundation

/// Assembles the prompt sent to the local LLM, and validates the JSON
/// returned against the contract locked in EPIC #1.
///
/// **Issue #4.** Pure-logic service: no PHI persistence, no HTTP, no
/// actor isolation. Transcript content passes through `buildPrompt` and
/// LLM response text passes through `validate` in-memory only.
///
/// **Template.** `Resources/Prompts/soap_v1.txt`, loadable so the prompt
/// can be tuned without recompiling the app. Two placeholders:
/// `{{manipulations_list}}` (rendered from `ManipulationsRepository`) and
/// `{{transcript}}`.
///
/// **Validation.** `validate(json:)` is forgiving about cosmetic wrapping
/// (whitespace, code fences, trailing commentary) and strict about the
/// schema — a response that does not decode to `RawLLMDraft` or whose
/// `manipulations[].confidence` falls outside `[0, 1]` is rejected with a
/// typed `SchemaError`.
struct ClinicalNotesPromptBuilder: Sendable {
    let template: String
    let manipulations: ManipulationsRepository

    /// Load the bundled prompt template.
    ///
    /// - Throws: `ClinicalNotesPromptBuilderError.templateNotFound` if
    ///   the named template is missing from the bundle.
    static func loadFromBundle(
        _ bundle: Bundle = .module,
        templateResource: String = "soap_v1",
        templateSubdirectory: String = "Prompts",
        manipulations: ManipulationsRepository
    ) throws -> ClinicalNotesPromptBuilder {
        guard let url = bundle.url(
            forResource: templateResource,
            withExtension: "txt",
            subdirectory: templateSubdirectory
        ) else {
            throw ClinicalNotesPromptBuilderError.templateNotFound(
                resource: templateResource,
                subdirectory: templateSubdirectory
            )
        }
        let template = try String(contentsOf: url, encoding: .utf8)
        return ClinicalNotesPromptBuilder(
            template: template,
            manipulations: manipulations
        )
    }

    // MARK: - Prompt assembly

    /// Substitute the template placeholders with the live taxonomy and
    /// the supplied transcript. The manipulations list is rendered as
    /// `- id: <id>, name: <display_name>` lines so the LLM can map its
    /// free-text `name` output back to a stable id downstream.
    ///
    /// Substitution order is load-bearing: `{{manipulations_list}}` is
    /// replaced first, then `{{transcript}}`. Doing manipulations first
    /// means a transcript that literally contains the string
    /// `{{manipulations_list}}` (or `{{transcript}}`) is inserted
    /// verbatim without re-triggering substitution.
    func buildPrompt(transcript: String) -> String {
        let list = manipulations.all
            .map { "- id: \($0.id), name: \($0.displayName)" }
            .joined(separator: "\n")
        return template
            .replacingOccurrences(of: "{{manipulations_list}}", with: list)
            .replacingOccurrences(of: "{{transcript}}", with: transcript)
    }

    // MARK: - Response validation

    /// Parse and validate the LLM's JSON response.
    ///
    /// Tolerates: leading / trailing whitespace, ```` ```json … ``` ````
    /// and bare ```` ``` … ``` ```` code fences, and trailing commentary
    /// after the final closing brace.
    ///
    /// Rejects:
    /// - empty or whitespace-only input → `.emptyInput`
    /// - input with no recognisable JSON object → `.noJSONFound`
    /// - JSON that doesn't decode to `RawLLMDraft` → `.decodingFailed`
    /// - any `manipulations[].confidence` outside `[0, 1]`
    ///   → `.confidenceOutOfRange(name:value:)`
    func validate(json: String) -> Result<RawLLMDraft, SchemaError> {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(.emptyInput)
        }

        let unfenced = Self.stripCodeFence(trimmed)

        guard let object = Self.firstJSONObject(in: unfenced) else {
            return .failure(.noJSONFound)
        }

        do {
            let draft = try JSONDecoder().decode(
                RawLLMDraft.self,
                from: Data(object.utf8)
            )
            if let offender = draft.manipulations.first(where: {
                $0.confidence < 0 || $0.confidence > 1
            }) {
                return .failure(.confidenceOutOfRange(
                    name: offender.name,
                    value: offender.confidence
                ))
            }
            return .success(draft)
        } catch {
            return .failure(.decodingFailed(Self.redact(error)))
        }
    }

    /// Map `DecodingError` into a PHI-safe structural description. Only
    /// schema-level context is preserved — never the offending value.
    ///
    /// `DecodingError`'s default `debugDescription` can quote the value
    /// that failed to decode (e.g. "Expected Double but found a String
    /// instead: \"high\""). If that value ever came from a transcript-
    /// derived SOAP field, interpolating the raw error description into a
    /// log or telemetry line would leak PHI. By capturing only the
    /// `codingPath` we keep the diagnostic useful while staying within
    /// the rules in `.claude/references/phi-handling.md`.
    private static func redact(_ error: any Error) -> DecodingFailureKind {
        guard let decodingError = error as? DecodingError else {
            return .other
        }
        switch decodingError {
        case .keyNotFound(let key, let context):
            return .missingKey(keyPath: keyPath(context.codingPath + [key]))
        case .valueNotFound(_, let context):
            return .missingKey(keyPath: keyPath(context.codingPath))
        case .typeMismatch(_, let context):
            return .typeMismatch(keyPath: keyPath(context.codingPath))
        case .dataCorrupted(let context):
            return .dataCorrupted(keyPath: keyPath(context.codingPath))
        @unknown default:
            return .other
        }
    }

    /// Render a `DecodingError.Context.codingPath` as a dotted string
    /// using schema keys + integer array indices only. Both are static
    /// structural values — never PHI.
    private static func keyPath(_ path: [any CodingKey]) -> String {
        path.map { key in
            if let intValue = key.intValue {
                return String(intValue)
            }
            return key.stringValue
        }.joined(separator: ".")
    }

    // MARK: - Private helpers

    /// Strip a single outer ``` or ```json fence, if present. Idempotent
    /// on unfenced input.
    private static func stripCodeFence(_ input: String) -> String {
        var body = input
        if body.hasPrefix("```json") {
            body = String(body.dropFirst("```json".count))
        } else if body.hasPrefix("```") {
            body = String(body.dropFirst("```".count))
        }
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasSuffix("```") {
            body = String(body.dropLast("```".count))
        }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Return the substring of the first balanced top-level JSON object
    /// in `input`, or `nil` if none is found. Walks the string
    /// brace-by-brace, tracking string literals + escapes so that braces
    /// inside JSON strings are not counted.
    private static func firstJSONObject(in input: String) -> String? {
        guard let start = input.firstIndex(of: "{") else { return nil }
        var state = BraceScanner()
        var idx = start
        while idx < input.endIndex {
            if state.step(input[idx]) {
                return String(input[start...idx])
            }
            idx = input.index(after: idx)
        }
        return nil
    }
}

/// Private state machine for `ClinicalNotesPromptBuilder.firstJSONObject`.
/// Tracks brace depth + in-string / escape context so a `{` or `}`
/// inside a JSON string literal does not confuse the top-level scan.
/// Extracted so each step fits under SwiftLint's cyclomatic-complexity
/// limit.
private struct BraceScanner {
    private var depth = 0
    private var inString = false
    private var escaped = false

    /// Consume one character. Returns `true` iff this character closes
    /// the outer JSON object (i.e. depth returned to zero on a `}`).
    mutating func step(_ char: Character) -> Bool {
        if escaped {
            escaped = false
            return false
        }
        if inString {
            stepInString(char)
            return false
        }
        return stepOutsideString(char)
    }

    private mutating func stepInString(_ char: Character) {
        if char == "\\" {
            escaped = true
        } else if char == "\"" {
            inString = false
        }
    }

    private mutating func stepOutsideString(_ char: Character) -> Bool {
        switch char {
        case "\"":
            inString = true
        case "{":
            depth += 1
        case "}":
            depth -= 1
            return depth == 0
        default:
            break
        }
        return false
    }
}

/// Errors surfaced by `ClinicalNotesPromptBuilder.validate(json:)`.
///
/// Every case is structural only. No PHI (transcript content, patient
/// data, SOAP body text, or decoded values) is carried in any payload —
/// payloads are schema key names, integer array indices, and the
/// technique name returned by the model (which is drawn from the static
/// taxonomy, not patient data).
enum SchemaError: Error, Equatable {
    /// Input was empty or whitespace-only.
    case emptyInput
    /// No `{ … }` JSON object could be located in the input.
    case noJSONFound
    /// JSON parsed, but did not match the `RawLLMDraft` shape. The
    /// associated kind carries only the schema key path that failed —
    /// never the offending value. See `DecodingFailureKind` for detail.
    case decodingFailed(DecodingFailureKind)
    /// A `manipulations[]` entry carried a `confidence` outside the
    /// locked `[0, 1]` range. `name` is the technique name returned by
    /// the model (one of the taxonomy entries); it is not patient data.
    case confidenceOutOfRange(name: String, value: Double)
}

/// PHI-safe structural description of a `DecodingError`.
///
/// The raw `DecodingError.debugDescription` can quote the offending
/// value, which in this pipeline may have been derived from transcript
/// text. This type preserves only the schema `codingPath` (dotted
/// schema keys + integer array indices), which is never PHI.
enum DecodingFailureKind: Error, Equatable, Sendable {
    /// A required schema key was missing (or its value was `null` on a
    /// non-optional field). `keyPath` is the dotted schema path — e.g.
    /// `"plan"` or `"manipulations.0.confidence"`.
    case missingKey(keyPath: String)
    /// A value at `keyPath` was present but of the wrong type. The
    /// offending value is deliberately not captured.
    case typeMismatch(keyPath: String)
    /// JSON parsed to the expected outer shape but failed a deeper
    /// data-corruption check (e.g. malformed nested structure).
    case dataCorrupted(keyPath: String)
    /// Any other decoding failure (future `DecodingError` variants).
    case other
}

/// Failures surfaced by `ClinicalNotesPromptBuilder.loadFromBundle(_:)`.
enum ClinicalNotesPromptBuilderError: Error, Equatable {
    /// The named template resource is missing from the bundle. Usually a
    /// build-system misconfiguration (e.g. a missing `.copy(...)` entry
    /// in `Package.swift`).
    case templateNotFound(resource: String, subdirectory: String)
}
