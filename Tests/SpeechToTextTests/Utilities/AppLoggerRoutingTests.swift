// AppLoggerRoutingTests.swift
// macOS Local Speech-to-Text Application
//
// Pins shared AppLogger categories used by Cliniko / Clinical Notes (#ARC-7).

import OSLog
import Testing
@testable import SpeechToText

@Suite("AppLogger routing", .tags(.fast))
struct AppLoggerRoutingTests {
    @Test("Cliniko and clinical-notes surfaces use shared AppLogger categories")
    func sharedCategoriesExist() {
        #expect(String(describing: AppLogger.cliniko).contains("cliniko"))
        #expect(String(describing: AppLogger.service).contains("service"))
        #expect(String(describing: AppLogger.viewModel).contains("viewModel"))
    }
}
