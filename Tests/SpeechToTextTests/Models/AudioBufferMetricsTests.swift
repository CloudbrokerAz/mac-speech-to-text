import Testing
@testable import SpeechToText

@Suite("AudioBuffer metrics", .tags(.fast))
struct AudioBufferMetricsTests {

    @Test("computeMetrics matches AudioBuffer peak and RMS")
    func computeMetrics_matchesInitializer() {
        let samples: [Int16] = [100, -500, 300, -1000, 500]
        let buffer = AudioBuffer(samples: samples)
        let metrics = AudioBuffer.computeMetrics(samples: samples)

        #expect(metrics.peak == buffer.peakAmplitude)
        #expect(abs(metrics.rms - buffer.rmsLevel) < 0.01)
    }

    @Test("computeMetrics returns zero for empty input")
    func computeMetrics_emptySamples() {
        let metrics = AudioBuffer.computeMetrics(samples: [])
        #expect(metrics.peak == 0)
        #expect(metrics.rms == 0)
    }
}
