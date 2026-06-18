import Foundation

/// Represents a single speech-to-text capture event from start to completion
struct RecordingSession: Identifiable, Sendable, Codable {
    let id: UUID
    let startTime: Date
    var endTime: Date?
    var duration: TimeInterval {
        guard let endTime = endTime else {
            return Date().timeIntervalSince(startTime)
        }
        return endTime.timeIntervalSince(startTime)
    }
    var audioData: [Int16]?
    var transcribedText: String
    let language: SupportedLanguage
    var confidenceScore: Double
    var insertionSuccess: Bool
    var errorMessage: String?
    var peakAmplitude: Int16
    var wordCount: Int {
        transcribedText.components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .count
    }
    var segments: [TranscriptionSegment]
    var state: SessionState

    init(id: UUID = UUID(),
         startTime: Date = Date(),
         language: SupportedLanguage = .en,
         state: SessionState = .idle) {
        self.id = id
        self.startTime = startTime
        self.endTime = nil
        self.audioData = nil
        self.transcribedText = ""
        self.language = language
        self.confidenceScore = 0.0
        self.insertionSuccess = false
        self.errorMessage = nil
        self.peakAmplitude = 0
        self.segments = []
        self.state = state
    }

    /// Wire-language convenience for call sites that still hold a code string.
    init(id: UUID = UUID(),
         startTime: Date = Date(),
         languageCode: String,
         state: SessionState = .idle) {
        self.init(
            id: id,
            startTime: startTime,
            language: SupportedLanguage.from(code: languageCode) ?? .en,
            state: state
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, startTime, endTime, audioData, transcribedText, language
        case confidenceScore, insertionSuccess, errorMessage, peakAmplitude
        case segments, state
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        startTime = try container.decode(Date.self, forKey: .startTime)
        endTime = try container.decodeIfPresent(Date.self, forKey: .endTime)
        audioData = try container.decodeIfPresent([Int16].self, forKey: .audioData)
        transcribedText = try container.decodeIfPresent(String.self, forKey: .transcribedText) ?? ""
        if let code = try container.decodeIfPresent(String.self, forKey: .language) {
            language = SupportedLanguage.from(code: code) ?? .en
        } else {
            language = .en
        }
        confidenceScore = try container.decodeIfPresent(Double.self, forKey: .confidenceScore) ?? 0.0
        insertionSuccess = try container.decodeIfPresent(Bool.self, forKey: .insertionSuccess) ?? false
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        peakAmplitude = try container.decodeIfPresent(Int16.self, forKey: .peakAmplitude) ?? 0
        segments = try container.decodeIfPresent([TranscriptionSegment].self, forKey: .segments) ?? []
        state = try container.decodeIfPresent(SessionState.self, forKey: .state) ?? .idle
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(startTime, forKey: .startTime)
        try container.encodeIfPresent(endTime, forKey: .endTime)
        try container.encodeIfPresent(audioData, forKey: .audioData)
        try container.encode(transcribedText, forKey: .transcribedText)
        try container.encode(language, forKey: .language)
        try container.encode(confidenceScore, forKey: .confidenceScore)
        try container.encode(insertionSuccess, forKey: .insertionSuccess)
        try container.encodeIfPresent(errorMessage, forKey: .errorMessage)
        try container.encode(peakAmplitude, forKey: .peakAmplitude)
        try container.encode(segments, forKey: .segments)
        try container.encode(state, forKey: .state)
    }

    /// Validation check for session data
    var isValid: Bool {
        // End time must be after start time
        if let endTime = endTime, endTime < startTime {
            return false
        }

        // Confidence score must be between 0 and 1
        if confidenceScore < 0.0 || confidenceScore > 1.0 {
            return false
        }

        return true
    }
}

/// Represents word-level timestamps in transcription
struct TranscriptionSegment: Identifiable, Sendable, Codable {
    let id: UUID
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let confidence: Double

    init(id: UUID = UUID(),
         text: String,
         startTime: TimeInterval,
         endTime: TimeInterval,
         confidence: Double) {
        self.id = id
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
    }
}

/// State machine for recording session lifecycle
enum SessionState: String, Codable, CaseIterable, Sendable {
    case idle
    case recording
    case transcribing
    case inserting
    case completed
    case cancelled

    var description: String {
        switch self {
        case .idle: return "Idle"
        case .recording: return "Recording..."
        case .transcribing: return "Transcribing..."
        case .inserting: return "Inserting text..."
        case .completed: return "Completed"
        case .cancelled: return "Cancelled"
        }
    }

    var isActive: Bool {
        switch self {
        case .recording, .transcribing, .inserting:
            return true
        case .idle, .completed, .cancelled:
            return false
        }
    }
}
