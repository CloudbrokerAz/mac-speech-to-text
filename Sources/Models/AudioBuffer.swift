import Foundation

/// Represents in-memory audio data during recording
struct AudioBuffer: Sendable {
    let samples: [Int16]
    let sampleRate: Int
    let channels: Int
    let duration: TimeInterval
    let peakAmplitude: Int16
    let rmsLevel: Double
    let timestamp: Date

    init(samples: [Int16],
         sampleRate: Int = 16000,
         channels: Int = 1,
         timestamp: Date = Date()) {
        precondition(sampleRate > 0, "Sample rate must be positive")
        precondition(channels > 0, "Channels must be positive")

        self.samples = samples
        self.sampleRate = sampleRate
        self.channels = channels
        self.duration = Double(samples.count) / Double(sampleRate * channels)
        self.timestamp = timestamp

        let metrics = Self.computeMetrics(samples: samples)
        self.peakAmplitude = metrics.peak
        self.rmsLevel = metrics.rms
    }

    /// Single-pass peak + RMS without libm `pow()` per sample (PRF-12).
    static func computeMetrics(samples: [Int16]) -> (peak: Int16, rms: Double) {
        guard !samples.isEmpty else { return (0, 0) }

        var peak: Int16 = 0
        var sumSquares: Double = 0

        for sample in samples {
            let magnitude: Int16 = sample == Int16.min ? Int16.max : abs(sample)
            if magnitude > peak {
                peak = magnitude
            }
            let value = Double(sample)
            sumSquares += value * value
        }

        return (peak, sqrt(sumSquares / Double(samples.count)))
    }

    var isValid: Bool {
        sampleRate == 16000 &&
        channels == 1 &&
        !samples.isEmpty &&
        peakAmplitude > 0  // Meaningful check: buffer has actual audio content
    }
}

/// Streaming audio buffer for real-time capture
/// Thread-safe actor for concurrent access from audio callback thread
actor StreamingAudioBuffer {
    private(set) var chunks: [AudioBuffer] = []
    let maxChunkSize: Int

    var totalDuration: TimeInterval {
        chunks.reduce(0) { $0 + $1.duration }
    }

    var isComplete: Bool = false

    var allSamples: [Int16] {
        chunks.flatMap { $0.samples }
    }

    init(maxChunkSize: Int = 1600) { // 100ms chunks at 16kHz
        self.maxChunkSize = maxChunkSize
    }

    func append(_ buffer: AudioBuffer) {
        chunks.append(buffer)
    }

    func clear() {
        chunks.removeAll()
        isComplete = false
    }

    func markComplete() {
        isComplete = true
    }

    var currentLevel: Double {
        guard let lastChunk = chunks.last else { return 0.0 }
        return lastChunk.rmsLevel
    }

    var peakLevel: Int16 {
        chunks.map { $0.peakAmplitude }.max() ?? 0
    }
}
