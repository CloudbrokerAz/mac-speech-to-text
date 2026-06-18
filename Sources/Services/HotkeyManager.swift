import Foundation
import KeyboardShortcuts

/// HotkeyManager handles global keyboard shortcut detection for hold-to-record functionality.
/// Uses the KeyboardShortcuts library for reliable cross-app hotkey handling.
@MainActor
class HotkeyManager {
    // MARK: - State Tracking

    private var keyPressStartTime: Date?
    private var activeSession: HotkeyRecordingSession = .idle

    // MARK: - Callbacks

    /// Called when the hotkey is pressed down and recording should start
    var onRecordingStart: (() async -> Void)?

    /// Called when the hotkey is released and recording should stop (with hold duration)
    var onRecordingStop: ((TimeInterval) async -> Void)?

    /// Called when recording is cancelled (e.g., hold duration too short)
    var onRecordingCancel: (() async -> Void)?

    /// Called when voice monitoring should be toggled
    var onVoiceMonitoringToggle: (() async -> Void)?

    /// Called when the clinical-notes recording chord starts a session (#91).
    /// AppDelegate posts `.showRecordingModal` so the existing observer presents
    /// `LiquidGlassRecordingModal`, which auto-starts recording on appear.
    var onClinicalNotesRecordingStart: (() async -> Void)?

    /// Called when the clinical-notes recording chord ends an active session (#91).
    /// AppDelegate defers to the modal's existing recording lifecycle by invoking
    /// `RecordingViewModel.stopRecording()` on the active modal — so transcription
    /// and the Generate Notes flow run identically to the modal's Done button.
    var onClinicalNotesRecordingStop: (() async -> Void)?

    // MARK: - Configuration

    /// Minimum hold duration required to trigger transcription (prevents accidental taps)
    let minimumHoldDuration: TimeInterval

    /// Cooldown interval between actions to prevent rapid re-triggers
    let cooldownInterval: TimeInterval

    /// Last completed action time for cooldown tracking
    private(set) var lastActionTime: Date = .distantPast

    // MARK: - Testability

    /// Allows injecting a custom time provider for deterministic testing
    var currentTimeProvider: () -> Date = { Date() }

    /// Exposes processing state for testing
    var isCurrentlyProcessing: Bool { activeSession.isGeneralDictationActive }

    /// Exposes toggle mode state for testing
    var isCurrentlyInToggleMode: Bool { activeSession.isToggleMode }

    /// Exposes clinical-notes recording state for testing (#91)
    var isCurrentlyRecordingClinicalNotes: Bool { activeSession.isClinicalNotesActive }

    /// Active hotkey session kind (#ARC-10).
    var activeHotkeyRecordingSession: HotkeyRecordingSession { activeSession }

    // MARK: - Lifecycle

    /// Initialize with default configuration
    convenience init() {
        self.init(minimumHoldDuration: 0.1, cooldownInterval: 0.3, skipHotkeySetup: false)
    }

    /// Initialize with custom configuration (for testing)
    init(minimumHoldDuration: TimeInterval = 0.1, cooldownInterval: TimeInterval = 0.3, skipHotkeySetup: Bool = false) {
        self.minimumHoldDuration = minimumHoldDuration
        self.cooldownInterval = cooldownInterval

        if !skipHotkeySetup {
            setupHotkey()
        }
    }

    /// Whether hotkeys have been disabled via shutdown()
    private var hasShutdown: Bool = false

    /// Explicitly shutdown the hotkey manager - MUST be called before releasing the instance
    /// This should be called from applicationWillTerminate or when the manager is no longer needed
    func shutdown() {
        guard !hasShutdown else { return }
        hasShutdown = true

        AppLogger.app.debug("HotkeyManager: shutdown() - disabling hotkeys")
        KeyboardShortcuts.disable(.holdToRecord)
        KeyboardShortcuts.disable(.toggleRecording)
        KeyboardShortcuts.disable(.toggleVoiceMonitoring)
        KeyboardShortcuts.disable(.clinicalNotesRecord)
        AppLogger.app.debug("HotkeyManager: shutdown() - hotkeys disabled successfully")
    }

    deinit {
        // Note: shutdown() should be called explicitly before deallocation
        // We can't reliably disable hotkeys from deinit since it's nonisolated
        // and KeyboardShortcuts.disable requires MainActor
        if !hasShutdown {
            // Log warning if shutdown wasn't called - indicates a bug in the caller
            AppLogger.app.warning("HotkeyManager deallocated without calling shutdown() - hotkeys may not be properly disabled")
        }
    }

    // MARK: - Hotkey Setup

    private func setupHotkey() {
        // Register handlers for the hold-to-record shortcut.
        // The default shortcut (Ctrl+Shift+Space) is defined in ShortcutNames.swift.
        // KeyboardShortcuts library handles storage and default fallback automatically.
        //
        // NOTE: Do NOT call KeyboardShortcuts.getShortcut() here - it crashes due to
        // Bundle.module not being available in executable targets.

        AppLogger.app.debug("HotkeyManager: setupHotkey() called")

        // First, explicitly enable the shortcut to ensure Carbon hotkey is registered
        KeyboardShortcuts.enable(.holdToRecord)
        AppLogger.app.debug("HotkeyManager: Enabled .holdToRecord shortcut")

        KeyboardShortcuts.onKeyDown(for: .holdToRecord) { [weak self] in
            AppLogger.app.debug("HotkeyManager: onKeyDown callback triggered")
            Task { @MainActor in
                await self?.handleKeyDown()
            }
        }

        KeyboardShortcuts.onKeyUp(for: .holdToRecord) { [weak self] in
            AppLogger.app.debug("HotkeyManager: onKeyUp callback triggered")
            Task { @MainActor in
                await self?.handleKeyUp()
            }
        }

        AppLogger.app.debug("HotkeyManager: Registered handlers for .holdToRecord (Ctrl+Shift+Space)")

        // Also set up toggle mode hotkey
        setupToggleModeHotkey()

        // Set up voice monitoring toggle hotkey
        setupVoiceMonitoringHotkey()

        // Set up clinical-notes recording hotkey (#91).
        // Listener is registered unconditionally, but the shortcut is unbound by default
        // and ClinicalNotesSection / AppDelegate enable/disable it based on the
        // Clinical Notes Mode toggle + Cliniko credential state.
        setupClinicalNotesHotkey()
    }

    private func setupToggleModeHotkey() {
        KeyboardShortcuts.enable(.toggleRecording)
        AppLogger.app.debug("HotkeyManager: Enabled .toggleRecording shortcut")

        KeyboardShortcuts.onKeyDown(for: .toggleRecording) { [weak self] in
            AppLogger.app.debug("HotkeyManager: onKeyDown callback triggered for toggle mode")
            Task { @MainActor in
                await self?.handleToggleKeyPress()
            }
        }

        AppLogger.app.debug("HotkeyManager: Registered handlers for .toggleRecording")
    }

    private func setupClinicalNotesHotkey() {
        KeyboardShortcuts.enable(.clinicalNotesRecord)
        AppLogger.app.debug("HotkeyManager: Enabled .clinicalNotesRecord shortcut")

        KeyboardShortcuts.onKeyDown(for: .clinicalNotesRecord) { [weak self] in
            Task { @MainActor in
                await self?.handleClinicalNotesKeyPress()
            }
        }

        AppLogger.app.debug("HotkeyManager: Registered handlers for .clinicalNotesRecord")
    }

    private func setupVoiceMonitoringHotkey() {
        KeyboardShortcuts.enable(.toggleVoiceMonitoring)
        AppLogger.app.debug("HotkeyManager: Enabled .toggleVoiceMonitoring shortcut")

        KeyboardShortcuts.onKeyDown(for: .toggleVoiceMonitoring) { [weak self] in
            AppLogger.app.debug("HotkeyManager: onKeyDown callback triggered for voice monitoring toggle")
            Task { @MainActor in
                await self?.onVoiceMonitoringToggle?()
            }
        }

        AppLogger.app.debug("HotkeyManager: Registered handlers for .toggleVoiceMonitoring")
    }

    /// Handle toggle key press - starts or stops recording in toggle mode (internal for testability)
    func handleToggleKeyPress() async {
        if activeSession == .toggle {
            activeSession = .idle
            await onRecordingStop?(0)
            return
        }

        guard activeSession == .idle else { return }

        activeSession = .toggle
        await onRecordingStart?()
    }

    func handleClinicalNotesKeyPress() async {
        if activeSession == .clinicalNotes {
            activeSession = .idle
            await onClinicalNotesRecordingStop?()
            return
        }

        guard activeSession == .idle else {
            AppLogger.app.debug("HotkeyManager: Ignoring clinical-notes keyPress - general dictation in flight")
            return
        }

        activeSession = .clinicalNotes
        await onClinicalNotesRecordingStart?()
    }

    func clinicalNotesSessionEnded() {
        if activeSession == .clinicalNotes {
            activeSession = .idle
            AppLogger.app.debug("HotkeyManager: clinicalNotesSessionEnded - state reset")
        }
    }

    func handleKeyDown() async {
        AppLogger.app.debug("HotkeyManager: handleKeyDown() - activeSession=\(String(describing: self.activeSession), privacy: .public)")

        guard activeSession == .idle else {
            AppLogger.app.debug("HotkeyManager: Ignoring keyDown - session already active")
            return
        }

        let now = currentTimeProvider()
        guard now.timeIntervalSince(lastActionTime) > cooldownInterval else {
            AppLogger.app.debug("HotkeyManager: Ignoring keyDown - in cooldown")
            return
        }

        activeSession = .hold
        keyPressStartTime = now
        AppLogger.app.debug("HotkeyManager: keyDown - starting recording")

        if let callback = onRecordingStart {
            await callback()
        } else {
            AppLogger.app.warning("HotkeyManager: onRecordingStart callback not set - recording may not start properly")
        }
    }

    func handleKeyUp() async {
        guard activeSession != .toggle else { return }

        guard activeSession == .hold, let startTime = keyPressStartTime else {
            AppLogger.app.debug("HotkeyManager: Ignoring keyUp - not processing hold session")
            return
        }

        let now = currentTimeProvider()
        let duration = now.timeIntervalSince(startTime)
        lastActionTime = now

        defer {
            keyPressStartTime = nil
            if activeSession == .hold {
                activeSession = .idle
            }
        }

        AppLogger.app.debug("HotkeyManager: keyUp - duration: \(duration)s")

        if duration >= minimumHoldDuration {
            if let callback = onRecordingStop {
                await callback(duration)
            } else {
                AppLogger.app.warning("HotkeyManager: onRecordingStop callback not set - transcription may not trigger")
            }
        } else {
            AppLogger.app.debug("HotkeyManager: Duration too short (\(duration)s < \(self.minimumHoldDuration)s) - cancelling")
            if let callback = onRecordingCancel {
                await callback()
            } else {
                AppLogger.app.warning("HotkeyManager: onRecordingCancel callback not set - session may not be cleaned up properly")
            }
        }
    }

    func cancel() {
        let previous = activeSession
        activeSession = .idle
        keyPressStartTime = nil

        if previous != .idle {
            AppLogger.app.debug("HotkeyManager: Recording cancelled (was=\(String(describing: previous), privacy: .public))")
        }
    }
}
