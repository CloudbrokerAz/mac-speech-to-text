// MenuBarViewModel.swift
// macOS Local Speech-to-Text Application
//
// Ultra-minimal ViewModel for menu bar: status icon + open/quit actions

import AppKit
import SwiftUI

/// Ultra-minimal menu bar ViewModel
@Observable
@MainActor
final class MenuBarViewModel {
    // MARK: - State

    /// Whether currently recording
    var isRecording: Bool = false

    /// Whether microphone permission is granted
    var hasPermission: Bool = false

    /// Whether Clinical Notes Mode is currently enabled in Settings (#92).
    /// Combined with `hasStoredCredentials` to gate the "Start Clinical Note"
    /// menu item — both must be true.
    private(set) var clinicalNotesModeEnabled: Bool = false

    /// Mirrors `ClinicalNotesSectionViewModel.CredentialLoadState` semantics so
    /// a transient Keychain read failure doesn't silently flip the gate to
    /// "absent". `.readFailed` is treated as "credentials may exist" for
    /// gating, matching the Settings UI.
    enum CredentialLoadState: Equatable {
        case unknown
        case present
        case absent
        case readFailed
    }

    /// What `hasAPIKey()` last reported. Updated by `refreshState()`.
    private(set) var credentialState: CredentialLoadState = .unknown

    // MARK: - Dependencies

    @ObservationIgnored private let permissionService: PermissionService
    @ObservationIgnored private let settingsService: SettingsService
    @ObservationIgnored private let credentialStore: ClinikoCredentialStore

    // MARK: - Initialization

    init(
        permissionService: PermissionService = PermissionService(),
        settingsService: SettingsService = SettingsService(),
        credentialStore: ClinikoCredentialStore = ClinikoCredentialStore()
    ) {
        self.permissionService = permissionService
        self.settingsService = settingsService
        self.credentialStore = credentialStore

        // Check microphone permission on init so the status icon is correct on
        // first paint. The clinical-notes gate (`refreshState()`) is left to
        // `MenuBarView`'s `.task` modifier so the same state-hydration path is
        // used on every menu open and there's no race between this init Task
        // and an explicit `refreshState()` call from a test or caller.
        Task { [weak self] in
            await self?.refreshPermission()
        }
    }

    // MARK: - Computed Properties

    /// Status icon based on current state
    var statusIcon: String {
        if !hasPermission {
            return "mic.slash"
        }
        return isRecording ? "mic.fill" : "mic.fill"
    }

    /// Icon color based on current state
    var iconColor: Color {
        if !hasPermission {
            return .gray
        }
        return isRecording ? .red : Color("AmberPrimary", bundle: nil)
    }

    // MARK: - Computed Gates

    /// Whether the Cliniko credential store currently reports a key. Mirrors
    /// `ClinicalNotesSectionViewModel.hasStoredCredentials`: returns true on
    /// `.readFailed` so a transient Keychain failure doesn't silently disable
    /// the gate (the user can still recover via Settings).
    var hasStoredCredentials: Bool {
        credentialState == .present || credentialState == .readFailed
    }

    /// Gate for the "Start Clinical Note" menu item (#92). Both Clinical Notes
    /// Mode AND Cliniko credentials must be present — same rule as the
    /// hotkey row in Settings (#91), and the menu item posts the same
    /// `.showRecordingModal` notification the hotkey does.
    var canStartClinicalNote: Bool {
        clinicalNotesModeEnabled && hasStoredCredentials
    }

    // MARK: - Actions

    /// Open the main application view
    func openMainView() {
        NotificationCenter.default.post(name: .showMainView, object: nil)
    }

    /// Trigger the clinical-notes recording modal (#92). Posts the same
    /// `.showRecordingModal` notification the dedicated hotkey (#91) uses, so
    /// the existing AppDelegate observer presents `LiquidGlassRecordingModal`
    /// (which auto-starts recording on present via its `.task(id:)`).
    func startClinicalNote() {
        NotificationCenter.default.post(name: .showRecordingModal, object: nil)
    }

    /// Quit the application
    func quit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Refresh

    /// Re-read settings + Cliniko credential presence to update
    /// `clinicalNotesModeEnabled` and `credentialState`. Called from the view's
    /// `.task` on each appearance so changes made elsewhere (Settings →
    /// toggle, credential save/remove) are reflected next time the menu opens.
    func refreshState() async {
        clinicalNotesModeEnabled = settingsService.load().general.clinicalNotesModeEnabled
        do {
            let present = try await credentialStore.hasAPIKey()
            credentialState = present ? .present : .absent
        } catch {
            // Treat read failure as "may exist" so the gate stays consistent
            // with the Settings UI; user can recover by re-entering the key.
            credentialState = .readFailed
            AppLogger.app.warning(
                "MenuBarViewModel: credential read failed (\(String(describing: type(of: error)), privacy: .public))"
            )
        }
    }

    // MARK: - Private Methods

    /// Refresh microphone permission status
    private func refreshPermission() async {
        hasPermission = await permissionService.checkMicrophonePermission()
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let showRecordingModal = Notification.Name("showRecordingModal")
    static let showSettings = Notification.Name("showSettings")
    static let showMainView = Notification.Name("showMainView")
    static let switchLanguage = Notification.Name("switchLanguage")
    /// Posted when voice trigger monitoring state changes (userInfo contains "state": VoiceTriggerState)
    static let voiceTriggerStateChanged = Notification.Name("voiceTriggerStateChanged")
    /// Posted when the practitioner taps "Generate Notes" in the recording
    /// modal with Clinical Notes Mode (#11) enabled. `userInfo["transcript"]`
    /// carries the just-finished transcript as `String`. The ReviewScreen
    /// presenter (#13) listens for this; until that lands, the AppDelegate
    /// listener is a no-op and the notification is purely a hand-off seam.
    static let clinicalNotesGenerateRequested = Notification.Name("clinicalNotesGenerateRequested")
}
