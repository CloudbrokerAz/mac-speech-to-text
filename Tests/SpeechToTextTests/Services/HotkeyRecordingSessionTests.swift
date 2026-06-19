// HotkeyRecordingSessionTests.swift
// macOS Local Speech-to-Text Application
//
// Coverage for hotkey / voice-trigger session enums (#ARC-10).

import Testing
@testable import SpeechToText

@Suite("HotkeyRecordingSession", .tags(.fast))
@MainActor
struct HotkeyRecordingSessionTests {
    @Test("HotkeyManager tracks active session via enum")
    func hotkeyManager_usesEnumState() async {
        let manager = HotkeyManager(skipHotkeySetup: true)
        #expect(manager.activeHotkeyRecordingSession == .idle)

        await manager.handleToggleKeyPress()
        #expect(manager.activeHotkeyRecordingSession == .toggle)
        #expect(manager.isCurrentlyInToggleMode)

        await manager.handleToggleKeyPress()
        #expect(manager.activeHotkeyRecordingSession == .idle)
    }

    @Test("Clinical notes session is mutually exclusive with hold")
    func hotkeyManager_clinicalNotesBlocksHold() async {
        let manager = HotkeyManager(skipHotkeySetup: true)
        await manager.handleClinicalNotesKeyPress()
        #expect(manager.activeHotkeyRecordingSession == .clinicalNotes)

        await manager.handleKeyDown()
        #expect(manager.activeHotkeyRecordingSession == .clinicalNotes)
    }
}

@Suite("VoiceTriggerInternalGuard", .tags(.fast))
struct VoiceTriggerInternalGuardTests {
    @Test("Voice trigger guard enum has expected cases")
    func guardCases() {
        #expect(VoiceTriggerInternalGuard.none != .transitioning)
        #expect(VoiceTriggerInternalGuard.handlingTimeout != .none)
    }
}
