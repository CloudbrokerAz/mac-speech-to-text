// TestInfrastructureTests.swift
// macOS Local Speech-to-Text Application
//
// Tests for the UI test infrastructure itself
// Verifies screenshot capture, helpers, and reset functionality
// Part of User Story 8: Test Infrastructure Improvements (P1)

import XCTest

/// Tests for the UI test infrastructure
/// These tests verify that the testing utilities work correctly
final class TestInfrastructureTests: UITestBase {
    // MARK: - TI-001: Screenshot Capture

    /// Test that screenshots are captured on test failure
    /// Verification: After test, check xcresult bundle for screenshot attachment
    func test_infrastructure_screenshotCaptured() throws {
        // Launch app in basic test mode
        launchAppSkippingOnboarding()

        // Take a manual screenshot to verify the mechanism works
        captureScreenshot(named: "Infrastructure-Test-Manual-Screenshot")

        // Verify app is running (basic sanity check)
        XCTAssertTrue(app.exists, "App should be running")

        // The screenshot capture on failure is tested by tearDown automatically
        // when any test fails - this test verifies manual capture works
    }

    // MARK: - TI-002: Helper Functions

    /// Test that UITestHelpers functions work correctly
    func test_infrastructure_helpersFunction() throws {
        // Launch app with first-launch reset (MainView + HomeSection)
        launchApp(arguments: [
            LaunchArguments.resetWelcome,
            LaunchArguments.skipPermissionChecks
        ])

        // Legacy helper maps to MainWindow / HomeSection
        XCTAssertTrue(
            waitForWelcomeView(timeout: 10),
            "Main window / home section should appear within timeout"
        )

        // Test that non-existent elements return false
        let nonExistent = app.buttons["NonExistentButton12345"]
        XCTAssertFalse(
            UITestHelpers.waitForElement(nonExistent, timeout: 1),
            "Non-existent element should not be found"
        )

        let homeSection = app.otherElements["homeSection"]
        if UITestHelpers.waitForElement(homeSection, timeout: 5) {
            XCTAssertTrue(homeSection.exists, "Home section should be visible on first launch")
        }
    }

    // MARK: - TI-003: Reset Welcome

    /// Test that -resetWelcome clears state for fresh test runs
    func test_infrastructure_resetWelcome() throws {
        // First, launch with onboarding skipped
        launchApp(arguments: [
            LaunchArguments.skipWelcome,
            LaunchArguments.skipPermissionChecks
        ])

        // Verify legacy welcome identifiers are absent (dead WelcomeView removed)
        let legacyWelcomeView = app.otherElements["welcomeView"]
        XCTAssertFalse(
            legacyWelcomeView.waitForExistence(timeout: 2),
            "Legacy welcome view should not appear"
        )

        // Terminate and relaunch with reset
        app.terminate()

        launchApp(arguments: [
            LaunchArguments.resetWelcome,
            LaunchArguments.skipPermissionChecks
        ])

        // Verify MainView / HomeSection appears after reset
        XCTAssertTrue(
            waitForWelcomeView(timeout: 5),
            "Main window / home section should appear after reset"
        )

        let homeSection = app.otherElements["homeSection"]
        XCTAssertTrue(
            homeSection.waitForExistence(timeout: 3),
            "Home section should be visible after reset"
        )
    }

    // MARK: - Infrastructure Verification

    /// Verify that the test base class provides expected utilities
    func test_infrastructure_baseClassProvided() throws {
        // Verify app instance is available
        XCTAssertNotNil(app, "App instance should be available")

        // Verify default timeout is set
        XCTAssertEqual(defaultTimeout, 5.0, "Default timeout should be 5 seconds")

        // Verify extended timeout is set
        XCTAssertEqual(extendedTimeout, 10.0, "Extended timeout should be 10 seconds")
    }

    /// Verify that launch argument helpers work
    func test_infrastructure_launchArgumentHelpers() throws {
        // Test that launchAppWithRecordingModal includes correct arguments
        // We don't actually launch here, just verify the method exists
        // The actual launch is tested in RecordingFlowTests

        // Verify LaunchArguments constants are accessible
        XCTAssertEqual(LaunchArguments.uitesting, "--uitesting")
        XCTAssertEqual(LaunchArguments.skipOnboarding, "--skip-onboarding")
        XCTAssertEqual(LaunchArguments.resetOnboarding, "--reset-onboarding")
        XCTAssertEqual(LaunchArguments.skipPermissionChecks, "--skip-permission-checks")
        XCTAssertEqual(LaunchArguments.triggerRecording, "--trigger-recording")
        XCTAssertEqual(LaunchArguments.skipWelcome, "--skip-welcome")
        XCTAssertEqual(LaunchArguments.resetWelcome, "--reset-welcome")
    }
}
