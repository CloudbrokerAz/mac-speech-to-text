// MainViewRenderTests.swift
// macOS Local Speech-to-Text Application
//
// ViewInspector render-crash + error-banner coverage for MainView (#ARC-6).

import SwiftUI
import ViewInspector
import XCTest
@testable import SpeechToText

extension MainView: Inspectable {}

@MainActor
final class MainViewRenderTests: XCTestCase {
    func test_mainView_instantiatesWithoutCrash() {
        let appState = AppState()
        let view = MainView().environment(appState)
        XCTAssertNotNil(view.body)
    }

    func test_mainView_surfacesAppStateErrorBanner() throws {
        let appState = AppState()
        appState.errorMessage = "Failed to save settings"
        let view = MainView().environment(appState)

        let inspected = try view.inspect()
        let banner = try inspected.find(viewWithAccessibilityIdentifier: "appStateErrorBanner")
        XCTAssertFalse(try banner.text().string().isEmpty)
    }
}
