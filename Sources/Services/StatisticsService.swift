import Foundation
import OSLog

/// Service for managing usage statistics with privacy preservation
/// Actor provides thread-safe access to shared mutable state
actor StatisticsService {
    /// UserDefaults is thread-safe, marked nonisolated(unsafe) for actor access
    private nonisolated(unsafe) let userDefaults: UserDefaults
    private let legacyStatsKey = "com.speechtotext.statistics"
    private let statsKeyPrefix = "com.speechtotext.statistics.day."

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private let dayKeyFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter
    }()

    private var didMigrateLegacyBlob = false

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    /// Record a completed session
    func recordSession(_ session: RecordingSession) throws {
        let today = Calendar.current.startOfDay(for: Date())
        var todayStats = loadStats(for: today) ?? UsageStatistics(date: today)

        todayStats.totalSessions += 1

        if session.insertionSuccess {
            todayStats.successfulSessions += 1
            todayStats.totalWordsTranscribed += session.wordCount
        } else {
            todayStats.failedSessions += 1
        }

        todayStats.totalDurationSeconds += session.duration

        // Update average confidence (weighted average)
        if todayStats.totalSessions > 1 {
            let oldWeight = Double(todayStats.totalSessions - 1)
            let newWeight = 1.0
            todayStats.averageConfidence =
                (todayStats.averageConfidence * oldWeight + session.confidenceScore * newWeight) /
                Double(todayStats.totalSessions)
        } else {
            todayStats.averageConfidence = session.confidenceScore
        }

        // Update language breakdown
        if let index = todayStats.languageBreakdown.firstIndex(where: { $0.languageCode == session.language.rawValue }) {
            todayStats.languageBreakdown[index].sessionCount += 1
            todayStats.languageBreakdown[index].wordCount += session.wordCount
        } else {
            todayStats.languageBreakdown.append(
                LanguageStats(languageCode: session.language.rawValue, sessionCount: 1, wordCount: session.wordCount)
            )
        }

        // Update error breakdown if failed
        if !session.insertionSuccess, let errorMessage = session.errorMessage {
            let errorType = extractErrorType(from: errorMessage)
            if let index = todayStats.errorBreakdown.firstIndex(where: { $0.errorType == errorType }) {
                todayStats.errorBreakdown[index].count += 1
            } else {
                todayStats.errorBreakdown.append(ErrorStats(errorType: errorType, count: 1))
            }
        }

        try saveStats(todayStats)
    }

    /// Get today's statistics
    func getTodayStats() -> UsageStatistics {
        let today = Calendar.current.startOfDay(for: Date())
        return getStatsForDate(today)
    }

    /// Get statistics for a specific date
    func getStatsForDate(_ date: Date) -> UsageStatistics {
        migrateLegacyStatsIfNeeded()
        let startOfDay = Calendar.current.startOfDay(for: date)
        return loadStats(for: startOfDay) ?? UsageStatistics(date: startOfDay)
    }

    /// Get aggregated statistics across different periods
    func getAggregatedStats() -> AggregatedStats {
        let allStats = loadAllStats()
        let calendar = Calendar.current
        let now = Date()

        let today = allStats.filter { calendar.isDateInToday($0.date) }
            .reduce(into: UsageStatistics(date: calendar.startOfDay(for: now))) { result, stats in
                result = merge(result, with: stats)
            }

        let thisWeek = allStats.filter { calendar.isDate($0.date, equalTo: now, toGranularity: .weekOfYear) }
            .reduce(into: UsageStatistics(date: calendar.startOfDay(for: now))) { result, stats in
                result = merge(result, with: stats)
            }

        let thisMonth = allStats.filter { calendar.isDate($0.date, equalTo: now, toGranularity: .month) }
            .reduce(into: UsageStatistics(date: calendar.startOfDay(for: now))) { result, stats in
                result = merge(result, with: stats)
            }

        let allTime = allStats.reduce(into: UsageStatistics(date: calendar.startOfDay(for: now))) { result, stats in
            result = merge(result, with: stats)
        }

        return AggregatedStats(today: today, thisWeek: thisWeek, thisMonth: thisMonth, allTime: allTime)
    }

    /// Clear all statistics
    func clearAll() {
        migrateLegacyStatsIfNeeded()
        for key in allDayStorageKeys() {
            userDefaults.removeObject(forKey: key)
        }
        userDefaults.removeObject(forKey: legacyStatsKey)
    }

    /// Clear statistics older than retention period
    func cleanupOldStats(retentionDays: Int) throws {
        guard retentionDays > 0 else { return }

        guard let cutoffDate = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) else {
            AppLogger.analytics.error("Failed to calculate cutoff date for cleanup with retention \(retentionDays) days")
            return
        }
        let allStats = loadAllStats()
        let recentStats = allStats.filter { $0.date >= cutoffDate }

        for key in allDayStorageKeys() {
            userDefaults.removeObject(forKey: key)
        }
        for stats in recentStats {
            try saveStats(stats)
        }
    }

    // MARK: - Private Helpers

    private func dayStorageKey(for date: Date) -> String {
        let startOfDay = Calendar.current.startOfDay(for: date)
        return statsKeyPrefix + dayKeyFormatter.string(from: startOfDay)
    }

    private func allDayStorageKeys() -> [String] {
        userDefaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(statsKeyPrefix) }
    }

    private func migrateLegacyStatsIfNeeded() {
        guard !didMigrateLegacyBlob else { return }
        didMigrateLegacyBlob = true

        guard let data = userDefaults.data(forKey: legacyStatsKey) else { return }

        do {
            let legacyStats = try decoder.decode([UsageStatistics].self, from: data)
            for stats in legacyStats {
                try saveStats(stats)
            }
            userDefaults.removeObject(forKey: legacyStatsKey)
            AppLogger.analytics.info("Migrated legacy statistics blob to per-day keys")
        } catch {
            AppLogger.analytics.error(
                "Failed to migrate legacy statistics: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func loadAllStats() -> [UsageStatistics] {
        migrateLegacyStatsIfNeeded()
        return allDayStorageKeys().compactMap { key in
            guard let data = userDefaults.data(forKey: key) else { return nil }
            do {
                return try decoder.decode(UsageStatistics.self, from: data)
            } catch {
                AppLogger.analytics.error(
                    "Failed to decode statistics for key \(key, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                return nil
            }
        }
        .sorted { $0.date < $1.date }
    }

    private func loadStats(for date: Date) -> UsageStatistics? {
        migrateLegacyStatsIfNeeded()
        let key = dayStorageKey(for: date)
        guard let data = userDefaults.data(forKey: key) else { return nil }

        do {
            return try decoder.decode(UsageStatistics.self, from: data)
        } catch {
            AppLogger.analytics.error(
                "Failed to decode statistics for key \(key, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            let backupKey = "\(key).corrupted"
            userDefaults.set(data, forKey: backupKey)
            AppLogger.analytics.info("Corrupted statistics data backed up to key: \(backupKey, privacy: .public)")
            return nil
        }
    }

    private func saveStats(_ stats: UsageStatistics) throws {
        let key = dayStorageKey(for: stats.date)
        let data = try encoder.encode(stats)
        userDefaults.set(data, forKey: key)
    }

    private func merge(_ lhs: UsageStatistics, with rhs: UsageStatistics) -> UsageStatistics {
        var result = lhs

        result.totalSessions += rhs.totalSessions
        result.successfulSessions += rhs.successfulSessions
        result.failedSessions += rhs.failedSessions
        result.totalWordsTranscribed += rhs.totalWordsTranscribed
        result.totalDurationSeconds += rhs.totalDurationSeconds

        // Weighted average for confidence
        if result.totalSessions > 0 {
            result.averageConfidence =
                (lhs.averageConfidence * Double(lhs.totalSessions) + rhs.averageConfidence * Double(rhs.totalSessions)) /
                Double(result.totalSessions)
        }

        // Merge language breakdown
        for rhsLang in rhs.languageBreakdown {
            if let index = result.languageBreakdown.firstIndex(where: { $0.languageCode == rhsLang.languageCode }) {
                result.languageBreakdown[index].sessionCount += rhsLang.sessionCount
                result.languageBreakdown[index].wordCount += rhsLang.wordCount
            } else {
                result.languageBreakdown.append(rhsLang)
            }
        }

        // Merge error breakdown
        for rhsError in rhs.errorBreakdown {
            if let index = result.errorBreakdown.firstIndex(where: { $0.errorType == rhsError.errorType }) {
                result.errorBreakdown[index].count += rhsError.count
            } else {
                result.errorBreakdown.append(rhsError)
            }
        }

        return result
    }

    private func extractErrorType(from message: String) -> String {
        let lowercased = message.lowercased()
        if lowercased.contains("permission") {
            return "permission_denied"
        } else if lowercased.contains("microphone") {
            return "microphone_error"
        } else if lowercased.contains("accessibility") {
            return "accessibility_error"
        } else if lowercased.contains("model") {
            return "model_error"
        } else if lowercased.contains("transcription") {
            return "transcription_error"
        } else {
            return "unknown_error"
        }
    }
}
