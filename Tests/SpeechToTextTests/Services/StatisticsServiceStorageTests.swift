import Foundation
import Testing
@testable import SpeechToText

@Suite("StatisticsService storage", .tags(.fast))
struct StatisticsServiceStorageTests {

    @Test("recordSession writes per-day key without legacy blob")
    func recordSession_usesPerDayKey() async throws {
        let suiteName = "com.speechtotext.stats.perday.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let service = StatisticsService(userDefaults: defaults)
        try await service.recordSession(RecordingSession(language: "en", state: .completed))

        let legacy = defaults.data(forKey: "com.speechtotext.statistics")
        #expect(legacy == nil)

        let dayKeys = defaults.dictionaryRepresentation().keys.filter {
            $0.hasPrefix("com.speechtotext.statistics.day.")
        }
        #expect(dayKeys.count == 1)

        let stats = await service.getTodayStats()
        #expect(stats.totalSessions == 1)
    }

    @Test("migrates legacy blob into per-day keys")
    func migrateLegacyBlob() async throws {
        let suiteName = "com.speechtotext.stats.migrate.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let today = Calendar.current.startOfDay(for: Date())
        let legacyStats = [UsageStatistics(date: today, totalSessions: 3)]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(legacyStats)
        defaults.set(data, forKey: "com.speechtotext.statistics")

        let service = StatisticsService(userDefaults: defaults)
        let stats = await service.getTodayStats()

        #expect(stats.totalSessions == 3)
        #expect(defaults.data(forKey: "com.speechtotext.statistics") == nil)
    }
}
