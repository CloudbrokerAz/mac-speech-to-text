import Foundation
import KeyboardShortcuts

/// HotkeyManager handles global keyboard shortcut detection for hold-to-record functionality.
/// Uses the KeyboardShortcuts library for reliable cross-app hotkey handling.
@MainActor
class HotkeyManager {
    // MARK: - State Tracking

    private var keyPressStartTime: Date?
    private var isProcessing: Bool = false
    private var isRecordingToggleMode: Bool = false

    /// Tracks whether a clinical-notes recording session is currently active (#91).
    /// Kept separate from `isProcessing` so the clinical-notes chord cannot interleave
    /// with hold-to-record / toggle-recording — and vice versa.
    private var isRecordingClinicalNotes: Bool = false

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
    var isCurrentlyProcessing: Bool { isProcessing }

    /// Exposes toggle mode state for testing
    var isCurrentlyInToggleMode: Bool { isRecordingToggleMode }

    /// Exposes clinical-notes recording state for testing (#91)
    var isCurrentlyRecordingClinicalNotes: Bool { isRecordingClinicalNotes }

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
            print("[WARNING] HotkeyManager deallocated without calling shutdown() - hotkeys may not be properly disabled")
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

        print("[DEBUG] HotkeyManager: setupHotkey() called")
        AppLogger.app.debug("HotkeyManager: setupHotkey() called")

        // First, explicitly enable the shortcut to ensure Carbon hotkey is registered
        print("[DEBUG] HotkeyManager: About to enable .holdToRecord shortcut...")
        KeyboardShortcuts.enable(.holdToRecord)
        print("[DEBUG] HotkeyManager: Enabled .holdToRecord shortcut")
        AppLogger.app.debug("HotkeyManager: Enabled .holdToRecord shortcut")

        KeyboardShortcuts.onKeyDown(for: .holdToRecord) { [weak self] in
            print("[DEBUG] HotkeyManager: onKeyDown callback triggered for holdToRecord!")
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
        AppLogger.app.info("[#109-probe] setupClinicalNotesHotkey: post-enable isEnabled=\(KeyboardShortcuts.isEnabled(for: .clinicalNotesRecord), privacy: .public)")

        KeyboardShortcuts.onKeyDown(for: .clinicalNotesRecord) { [weak self] in
            AppLogger.app.info("[#109-probe] onKeyDown fired for .clinicalNotesRecord (Carbon → KeyboardShortcuts dispatcher reached)")
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
        // If already in toggle mode, stop recording (even if isProcessing is true)
        if isRecordingToggleMode {
            isProcessing = false
            isRecordingToggleMode = false
            await onRecordingStop?(0) // Duration not tracked for toggle mode
            return
        }

        // Guard: don't start toggle mode if hold mode or clinical-notes mode is in progress
        guard !isProcessing, !isRecordingClinicalNotes else { return }

        // Start recording in toggle mode
        isProcessing = true
        isRecordingToggleMode = true
        await onRecordingStart?()
    }

    /// Handle clinical-notes key press (#91) - alternates between start/stop using a
    /// dedicated state flag so the chord cannot interleave with hold-to-record /
    /// toggle-recording sessions.
    func handleClinicalNotesKeyPress() async {
        AppLogger.app.info("[#109-probe] handleClinicalNotesKeyPress entered: isRecordingClinicalNotes=\(self.isRecordingClinicalNotes, privacy: .public) isProcessing=\(self.isProcessing, privacy: .public) isEnabled=\(KeyboardShortcuts.isEnabled(for: .clinicalNotesRecord), privacy: .public)")

        // If a clinical-notes session is active, stop it.
        if isRecordingClinicalNotes {
            AppLogger.app.info("[#109-probe] handleClinicalNotesKeyPress → STOP branch (chord state was active)")
            isRecordingClinicalNotes = false
            await onClinicalNotesRecordingStop?()
            return
        }

        // Guard: don't start a clinical-notes session if hold or toggle mode is in flight.
        // The general-dictation flow owns the modal/overlay surface in those states.
        guard !isProcessing else {
            AppLogger.app.debug("HotkeyManager: Ignoring clinical-notes keyPress - general dictation in flight")
            return
        }

        AppLogger.app.info("[#109-probe] handleClinicalNotesKeyPress → START branch (firing onClinicalNotesRecordingStart)")
        isRecordingClinicalNotes = true
        await onClinicalNotesRecordingStart?()
    }

    /// Notify HotkeyManager that the clinical-notes modal has closed so the
    /// chord state flag stays in sync with reality. Called from the modal's
    /// `.onDisappear` in `AppDelegate`. Required because the modal can close
    /// for reasons that don't go through the chord-stop callback — most
    /// commonly the in-modal **Done** button (which transcribes via the same
    /// `viewModel.stopRecording()` path the chord uses, but bypasses
    /// `handleClinicalNotesKeyPress`). Without this call, the next chord
    /// press sees a stale `isRecordingClinicalNotes == true`, takes the
    /// "stop" branch, fires a no-op stop callback (no active modal), and
    /// the user perceives the chord as broken until they press it again.
    /// Idempotent — safe to call from any close path.
    func clinicalNotesSessionEnded() {
        AppLogger.app.info("[#109-probe] clinicalNotesSessionEnded entered: was isRecordingClinicalNotes=\(self.isRecordingClinicalNotes, privacy: .public) isEnabled=\(KeyboardShortcuts.isEnabled(for: .clinicalNotesRecord), privacy: .public)")
        if isRecordingClinicalNotes {
            isRecordingClinicalNotes = false
            AppLogger.app.debug("HotkeyManager: clinicalNotesSessionEnded - state reset")
        }
    }

    // MARK: - Key Event Handlers (internal for testability)

    /// Handle key down event - starts recording if not already processing and not in cooldown
    func handleKeyDown() async {
        AppLogger.app.debug("HotkeyManager: handleKeyDown() - isProcessing=\(self.isProcessing)")

        // Guard: already processing
        guard !isProcessing else {
            AppLogger.app.debug("HotkeyManager: Ignoring keyDown - already processing")
            return
        }

        // Guard: clinical-notes session in flight owns the modal — don't double-trigger
        guard !isRecordingClinicalNotes else {
            AppLogger.app.debug("HotkeyManager: Ignoring keyDown - clinical notes session active")
            return
        }

        // Guard: in cooldown period
        let now = currentTimeProvider()
        guard now.timeIntervalSince(lastActionTime) > cooldownInterval else {
            AppLogger.app.debug("HotkeyManager: Ignoring keyDown - in cooldown")
            return
        }

        // Start recording
        isProcessing = true
        keyPressStartTime = now
        AppLogger.app.debug("HotkeyManager: keyDown - starting recording")

        if let callback = onRecordingStart {
            await callback()
        } else {
            AppLogger.app.warning("HotkeyManager: onRecordingStart callback not set - recording may not start properly")
        }
    }

    /// Handle key up event - stops recording and invokes appropriate callback
    func handleKeyUp() async {
        // Don't process keyUp if we're in toggle mode
        guard !isRecordingToggleMode else { return }

        guard isProcessing, let startTime = keyPressStartTime else {
            AppLogger.app.debug("HotkeyManager: Ignoring keyUp - not processing")
            return
        }

        // Calculate hold duration and apply cooldown immediately
        let now = currentTimeProvider()
        let duration = now.timeIntervalSince(startTime)
        lastActionTime = now // Apply cooldown immediately on key release

        // Use defer to ensure state is always cleaned up
        defer {
            keyPressStartTime = nil
            isProcessing = false
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

    // MARK: - Public Methods

    /// Cancel any in-progress recording without invoking callbacks
    func cancel() {
        let wasProcessing = isProcessing
        let wasToggleMode = isRecordingToggleMode
        let wasClinicalNotes = isRecordingClinicalNotes

        isProcessing = false
        keyPressStartTime = nil
        isRecordingToggleMode = false
        isRecordingClinicalNotes = false

        if wasProcessing || wasToggleMode || wasClinicalNotes {
            AppLogger.app.debug("HotkeyManager: Recording cancelled (wasProcessing=\(wasProcessing), wasToggleMode=\(wasToggleMode), wasClinicalNotes=\(wasClinicalNotes))")
        }
    }
}
