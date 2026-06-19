import Foundation

/// Active hotkey-owned recording session (#ARC-10).
///
/// Replaces the mutually exclusive bool flags previously scattered across
/// `HotkeyManager` (`isProcessing`, `isRecordingToggleMode`,
/// `isRecordingClinicalNotes`). Only one case may be active at a time.
enum HotkeyRecordingSession: Equatable, Sendable {
    case idle
    case hold
    case toggle
    case clinicalNotes

    /// Whether hold-to-record or toggle mode owns the dictation surface.
    var isGeneralDictationActive: Bool {
        self == .hold || self == .toggle
    }

    var isToggleMode: Bool {
        self == .toggle
    }

    var isClinicalNotesActive: Bool {
        self == .clinicalNotes
    }
}

/// Internal reentrancy guard for voice-trigger state transitions (#ARC-10).
enum VoiceTriggerInternalGuard: Equatable, Sendable {
    case none
    case transitioning
    case handlingTimeout
}
