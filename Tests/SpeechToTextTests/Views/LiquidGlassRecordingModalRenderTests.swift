// LiquidGlassRecordingModalRenderTests.swift
// macOS Local Speech-to-Text Application
//
// ViewInspector render-crash tests for LiquidGlassRecordingModal

import SwiftUI
import ViewInspector
import XCTest
@testable import SpeechToText

extension LiquidGlassRecordingModal: Inspectable {}

@MainActor
final class LiquidGlassRecordingModalRenderTests: XCTestCase {
    // MARK: - Clinical Mode Render Tests (#98)

    func test_liquidGlassRecordingModal_clinicalMode_instantiatesWithoutCrash() {
        let viewModel = RecordingViewModel(clinicalMode: true)
        let modal = LiquidGlassRecordingModal(viewModel: viewModel)
        XCTAssertNotNil(modal)
        XCTAssertTrue(viewModel.clinicalMode)
    }

    func test_liquidGlassRecordingModal_clinicalMode_bodyAccessDoesNotCrash() {
        let viewModel = RecordingViewModel(clinicalMode: true)
        viewModel.transcribedText = "Patient reports recurring tension headaches over the past two weeks."
        let modal = LiquidGlassRecordingModal(viewModel: viewModel)

        let body = modal.body
        XCTAssertNotNil(body)
    }

    func test_liquidGlassRecordingModal_generalDictation_instantiatesWithoutCrash() {
        let viewModel = RecordingViewModel(clinicalMode: false)
        viewModel.transcribedText = "hello world"
        let modal = LiquidGlassRecordingModal(viewModel: viewModel)

        let body = modal.body
        XCTAssertNotNil(body)
        XCTAssertFalse(viewModel.clinicalMode)
    }

    func test_liquidGlassRecordingModal_usesSettingsWaveformStyle() throws {
        let settingsService = SettingsService()
        var settings = settingsService.load()
        settings.ui.waveformStyle = .siriRings
        try settingsService.save(settings)

        let viewModel = RecordingViewModel(settingsService: settingsService)
        let modal = LiquidGlassRecordingModal(viewModel: viewModel)

        XCTAssertEqual(viewModel.waveformStyle, .siriRings)
        XCTAssertNotNil(modal.body)
    }

    func test_liquidGlassRecordingModal_clinicalMode_exposesTranscriptScrollView() throws {
        let viewModel = RecordingViewModel(clinicalMode: true)
        viewModel.transcribedText = String(repeating: "Patient reports persistent thoracic discomfort. ", count: 20)
        let modal = LiquidGlassRecordingModal(viewModel: viewModel)

        let view = try modal.inspect()
        XCTAssertNoThrow(
            try view.find(viewWithAccessibilityIdentifier: "clinicalTranscriptScrollView"),
            "Clinical transcript ScrollView (#98 Bug C) should be reachable when clinicalMode = true and transcribedText is non-empty"
        )
    }
}
