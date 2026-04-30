// HomeSection.swift
// macOS Local Speech-to-Text Application
//
// Main View - Home Section
// Displays recording status, permission cards, and typing animation demo
// Glassmorphism design with frosted glass effects

import KeyboardShortcuts
import SwiftUI

// MARK: - Permission Card Focus

/// Enumeration for focusable permission cards
enum PermissionCardFocus: Hashable {
    case microphone
    case accessibility
}

/// HomeSection displays the main dashboard with recording status and permission overview
/// Features glassmorphism design with frosted glass cards and glowing accents
struct HomeSection: View {
    // MARK: - Environment

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - Dependencies

    let settingsService: SettingsService
    let permissionService: PermissionService

    /// Cliniko credential store consulted to decide whether the
    /// "Start Clinical Note" trigger row is shown (#97). Default-injected
    /// to mirror `MenuBarViewModel` / `ClinicalNotesSectionViewModel` —
    /// `ClinikoCredentialStore` is a stateless wrapper around the
    /// `SecureStore` actor + `UserDefaults`, so multiple instances all read
    /// the same underlying state.
    let credentialStore: ClinikoCredentialStore

    // MARK: - Focus State

    @FocusState private var focusedCard: PermissionCardFocus?
    @Namespace private var homeFocusScope

    // MARK: - State

    @State private var isPulsing: Bool = false
    @State private var microphoneGranted: Bool = false
    @State private var accessibilityGranted: Bool = false
    @State private var lastTranscription: String = ""
    @State private var hasTestedSuccessfully: Bool = false
    @State private var settings: UserSettings

    // MARK: - Clinical Notes Gate (#97)

    /// Mirrors the rule in `ClinicalNotesSection` (`showShortcutRow`) and
    /// the now-removed menu-bar gate (#92): the trigger is visible only
    /// when Clinical Notes Mode is on AND Cliniko credentials are
    /// present. Hidden in all other states — the doctor either has the
    /// feature or doesn't (no greyed-out trigger).
    @State private var clinicalNotesGateOpen: Bool = false

    // MARK: - Initialization

    init(
        settingsService: SettingsService,
        permissionService: PermissionService,
        credentialStore: ClinikoCredentialStore = ClinikoCredentialStore()
    ) {
        self.settingsService = settingsService
        self.permissionService = permissionService
        self.credentialStore = credentialStore
        self._settings = State(initialValue: settingsService.load())
    }

    // Loading & Error States
    @State private var isMicrophoneLoading: Bool = false
    @State private var isAccessibilityPolling: Bool = false
    @State private var microphoneError: String?
    @State private var accessibilityError: String?

    // Task references for cancellation
    @State private var microphonePermissionTask: Task<Void, Never>?
    @State private var accessibilityPermissionTask: Task<Void, Never>?

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                // Hero section with animated mic icon
                heroSection
                    .padding(.top, 20)

                // Permission status cards in glass containers
                permissionCards

                // Hotkey hint (shown after permissions are set up)
                hotkeyHint

                // Typing animation preview
                typingPreview
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
        }
        .accessibilityIdentifier("homeSection")
        .task {
            await refreshPermissions()
            await refreshClinicalNotesGate()
            startPulseAnimation()
        }
        .onDisappear {
            microphonePermissionTask?.cancel()
            microphonePermissionTask = nil
            accessibilityPermissionTask?.cancel()
            accessibilityPermissionTask = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .transcriptionDidComplete)) { notification in
            if let text = notification.userInfo?["text"] as? String, !text.isEmpty {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                    lastTranscription = text
                    hasTestedSuccessfully = true
                }
            }
        }
        .focusScope(homeFocusScope)
        .onKeyPress(.tab) {
            // Only handle tab when focused on permission cards
            if focusedCard != nil {
                handleTabNavigation()
                return .handled
            }
            return .ignored  // Allow standard tab behavior otherwise
        }
        .onKeyPress(.return) {
            if focusedCard != nil {
                handleReturnKey()
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.space) {
            if focusedCard != nil {
                handleReturnKey()
                return .handled
            }
            return .ignored
        }
        .onAppear {
            // Reload settings on appear to ensure fresh state. The
            // Clinical Notes trigger gate (#97) is refreshed by the
            // `.task` modifier above — it re-fires on each appearance,
            // so a duplicate `Task { await refreshClinicalNotesGate() }`
            // here would be a redundant Keychain read with the same
            // answer. Mirrors the single-source pattern in
            // `ClinicalNotesSection.refreshState`.
            // Set initial focus to microphone card if no permissions granted.
            // Defer through the runloop so SwiftUI's FocusBridge applies the
            // focus AFTER the inner card views are attached to their window.
            // A synchronous set here races with attachment and triggers
            // AppKit's "first responder for window X, but it is in a
            // different window ((null))" warning. Mirrors the same hop
            // applied in `ReviewScreen.swift` and `MainView.swift`.
            DispatchQueue.main.async {
                if !microphoneGranted {
                    focusedCard = .microphone
                } else if !accessibilityGranted {
                    focusedCard = .accessibility
                }
            }
        }
        .onDisappear {
            // Clear focus before the section's NSHostingView teardown so
            // SwiftUI's FocusBridge has no pending responder to flush onto a
            // detached card view during the close transaction.
            focusedCard = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .settingsDidReset)) { _ in
            // Reload settings when they change
            settings = settingsService.load()
        }
    }

    // MARK: - Keyboard Navigation

    private func handleTabNavigation() {
        switch focusedCard {
        case .none:
            focusedCard = .microphone
        case .microphone:
            focusedCard = .accessibility
        case .accessibility:
            focusedCard = .microphone
        }
    }

    private func handleReturnKey() {
        switch focusedCard {
        case .microphone:
            if !microphoneGranted {
                requestMicrophonePermission()
            }
        case .accessibility:
            if !accessibilityGranted {
                requestAccessibilityPermission()
            }
        case .none:
            break
        }
    }

    // MARK: - Hero Section

    private var heroSection: some View {
        VStack(spacing: 24) {
            // Animated microphone icon with glow effect
            ZStack {
                // Outer pulse rings (hidden when reduce motion is enabled)
                if !reduceMotion {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        Color.amberPrimary.opacity(0.4),
                                        Color.amberPrimary.opacity(0.1)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1.5
                            )
                            .frame(width: CGFloat(80 + index * 24), height: CGFloat(80 + index * 24))
                            .scaleEffect(isPulsing ? 1.2 : 1.0)
                            .opacity(isPulsing ? 0.0 : 0.8 - Double(index) * 0.2)
                            .animation(
                                .easeInOut(duration: 2.0)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * 0.2),
                                value: isPulsing
                            )
                    }
                    .accessibilityHidden(true)  // Decorative elements
                }

                // Glass card background
                Circle()
                    .fill(
                        colorScheme == .dark
                            ? Color.white.opacity(0.08)
                            : Color.white.opacity(0.9)
                    )
                    .frame(width: 90, height: 90)
                    .background(.ultraThinMaterial, in: Circle())
                    .shadow(color: Color.amberPrimary.opacity(0.3), radius: 20, x: 0, y: 5)

                // Main icon with gradient
                Image(systemName: "mic.circle.fill")
                    .font(.system(size: 50))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.amberLight, .amberPrimary, .amberDark],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .symbolEffect(.pulse, options: reduceMotion ? .nonRepeating : .repeating, value: isPulsing)
                    .accessibilityLabel("Speech to Text - Ready to record")
            }
            .frame(height: 160)
            .accessibilityIdentifier("homeMicIcon")
        }
        .accessibilityIdentifier("heroSection")
    }

    // MARK: - Hotkey Section

    private var hotkeyHint: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Section label
            HStack {
                Text("RECORDING SHORTCUT")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.textTertiaryAdaptive)
                    .tracking(1.5)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
            }
            .padding(.horizontal, 4)

            // Hold-to-Record shortcut
            HStack {
                HStack(spacing: 12) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.amberPrimary)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hold to Record")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.primary)

                        Text("Hold the key to record, release to transcribe")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                VStack(spacing: 4) {
                    ShortcutRecorderView(for: .holdToRecord)
                        .accessibilityIdentifier("hotkeyRecorder")

                    Text("Click to change")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.cardBackgroundAdaptive)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.cardBorderAdaptive, lineWidth: 1)
                    )
            )
            .shadow(color: Color.cardShadowAdaptive, radius: 10, x: 0, y: 3)

            // Clinical Notes trigger row (#97)
            // Visible only when Clinical Notes Mode is on AND Cliniko
            // credentials are present. Hidden in all other states (no
            // greyed-out entries) — the doctor either has the feature
            // or doesn't. Tap posts the same `.showRecordingModal`
            // notification the dedicated hotkey (#91) and the now-
            // removed menu-bar item (#92, superseded by #97) used, so
            // the existing AppDelegate observer presents
            // `LiquidGlassRecordingModal` with `clinicalMode: true`.
            if clinicalNotesGateOpen {
                clinicalNoteTriggerRow
            }

            // Toggle Recording shortcut (only shown in toggle mode)
            if settings.ui.recordingMode == .toggle {
                HStack {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 18))
                            .foregroundStyle(Color.amberPrimary)
                            .frame(width: 28)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Toggle Recording")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.primary)

                            Text("Press to start, press again to stop")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    VStack(spacing: 4) {
                        ShortcutRecorderView(for: .toggleRecording, placeholder: "Set Toggle Key")
                            .accessibilityIdentifier("toggleRecordingRecorder")

                        Text("Click to change")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.cardBackgroundAdaptive)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(Color.cardBorderAdaptive, lineWidth: 1)
                        )
                )
                .shadow(color: Color.cardShadowAdaptive, radius: 10, x: 0, y: 3)
            }
        }
        .accessibilityIdentifier("hotkeySection")
    }

    // MARK: - Clinical Notes Trigger Row (#97)

    /// Trigger row that opens `LiquidGlassRecordingModal` with the PHI
    /// invariant active. Sits next to the Hold-to-Record / Toggle
    /// Recording rows so the doctor sees their three recording options
    /// in one place. Posts `.showRecordingModal` with
    /// `userInfo["clinicalMode"] = true` — the AppDelegate observer
    /// constructs `RecordingViewModel(clinicalMode: true)`, which is
    /// what stops the transcript from being pasted into the focused
    /// app via the general-dictation path.
    private var clinicalNoteTriggerRow: some View {
        Button {
            startClinicalNote()
        } label: {
            HStack {
                HStack(spacing: 12) {
                    Image(systemName: "stethoscope")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.amberPrimary)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Start Clinical Note")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.primary)

                        Text("Record a consultation and draft a SOAP note")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.cardBackgroundAdaptive)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.cardBorderAdaptive, lineWidth: 1)
                )
        )
        .shadow(color: Color.cardShadowAdaptive, radius: 10, x: 0, y: 3)
        .accessibilityIdentifier("homeStartClinicalNote")
        .accessibilityLabel("Start Clinical Note")
        .accessibilityHint("Records a consultation and drafts a SOAP note for review and Cliniko export")
    }

    // MARK: - Permission Cards

    private var permissionCards: some View {
        VStack(spacing: 14) {
            // Section label
            HStack {
                Text("PERMISSIONS")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.textTertiaryAdaptive)
                    .tracking(1.5)
                    .accessibilityAddTraits(.isHeader)

                Spacer()

                if allPermissionsGranted {
                    Label("All Ready", systemImage: "checkmark.seal.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.successGreen)
                        .accessibilityLabel("All permissions granted. Ready to use.")
                }
            }
            .padding(.horizontal, 4)

            // Microphone permission card
            GlassPermissionCard(
                icon: "mic.fill",
                title: "Microphone",
                subtitle: "Required for voice recording",
                isGranted: microphoneGranted,
                isLoading: isMicrophoneLoading,
                errorMessage: microphoneError,
                actionLabel: "Grant Access",
                isFocused: focusedCard == .microphone,
                colorScheme: colorScheme,
                onAction: requestMicrophonePermission,
                onDismissError: { microphoneError = nil }
            )
            .focusable()
            .focused($focusedCard, equals: .microphone)
            .focusEffectDisabled()  // Disable default blue focus ring
            .accessibilityIdentifier("microphonePermissionCard")

            // Accessibility permission card
            GlassPermissionCard(
                icon: "hand.raised.fill",
                title: "Accessibility",
                subtitle: "Required for text insertion",
                isGranted: accessibilityGranted,
                isLoading: isAccessibilityPolling,
                errorMessage: accessibilityError,
                actionLabel: "Enable",
                isFocused: focusedCard == .accessibility,
                colorScheme: colorScheme,
                onAction: requestAccessibilityPermission,
                onDismissError: { accessibilityError = nil }
            )
            .focusable()
            .focused($focusedCard, equals: .accessibility)
            .focusEffectDisabled()  // Disable default blue focus ring
            .accessibilityIdentifier("accessibilityPermissionCard")
        }
        .accessibilityIdentifier("permissionCards")
    }

    private var allPermissionsGranted: Bool {
        microphoneGranted && accessibilityGranted
    }

    // MARK: - Test Section

    private var typingPreview: some View {
        VStack(spacing: 12) {
            // Section label with status
            HStack {
                Text("TRY IT NOW")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.textTertiaryAdaptive)
                    .tracking(1.5)
                    .accessibilityAddTraits(.isHeader)

                Spacer()

                if hasTestedSuccessfully {
                    Label("Working!", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.successGreen)
                        .accessibilityLabel("Test successful")
                }
            }
            .padding(.horizontal, 4)

            // Test prompt or result
            VStack(alignment: .leading, spacing: 12) {
                if lastTranscription.isEmpty {
                    // Prompt to test
                    HStack(spacing: 12) {
                        Image(systemName: "mic.badge.plus")
                            .font(.system(size: 20))
                            .foregroundStyle(Color.amberPrimary)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Test your setup")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.primary)

                            Text("Press your hotkey and say something to verify everything is working")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else {
                    // Show transcription result
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "text.quote")
                                .font(.system(size: 14))
                                .foregroundStyle(Color.successGreen)

                            Text("Last transcription")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                        }

                        Text(lastTranscription)
                            .font(.system(size: 15))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        // Try again prompt
                        HStack {
                            Spacer()
                            Text("Press your hotkey to try again")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(hasTestedSuccessfully ? Color.successGreen.opacity(0.05) : Color.cardBackgroundAdaptive)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(
                                hasTestedSuccessfully ? Color.successGreen.opacity(0.3) : Color.cardBorderAdaptive,
                                lineWidth: 1
                            )
                    )
            )
            .shadow(color: Color.cardShadowAdaptive, radius: 10, x: 0, y: 3)
        }
        .accessibilityIdentifier("testSection")
    }

    // MARK: - Private Methods

    private func refreshPermissions() async {
        microphoneGranted = await permissionService.checkMicrophonePermission()
        accessibilityGranted = permissionService.checkAccessibilityPermission()
    }

    /// Re-read Clinical Notes Mode + Cliniko credential presence to
    /// decide whether `clinicalNoteTriggerRow` is visible (#97). A
    /// Keychain `.readFailed` is treated as "may exist", matching
    /// `ClinicalNotesSectionViewModel.hasStoredCredentials` — the user
    /// can still recover via Settings, and the gate must not silently
    /// flip closed on a transient lock.
    private func refreshClinicalNotesGate() async {
        let modeOn = settingsService.load().general.clinicalNotesModeEnabled
        guard modeOn else {
            clinicalNotesGateOpen = false
            return
        }
        do {
            let present = try await credentialStore.hasAPIKey()
            clinicalNotesGateOpen = present
        } catch {
            clinicalNotesGateOpen = true
            AppLogger.app.warning(
                "HomeSection: Cliniko credential read failed (\(String(describing: type(of: error)), privacy: .public)); leaving Start Clinical Note row visible"
            )
        }
    }

    /// Posts `.showRecordingModal` with `userInfo["clinicalMode"] =
    /// true`. The AppDelegate observer constructs the modal's view
    /// model with the PHI invariant active so the transcript is not
    /// pasted into the focused app via the general-dictation path.
    /// Same shape used by the dedicated hotkey
    /// (`AppDelegate.startClinicalNotesRecordingFromHotkey`) and the
    /// previously-shipped menu-bar item (#92 — superseded by #97).
    private func startClinicalNote() {
        NotificationCenter.default.post(
            name: .showRecordingModal,
            object: nil,
            userInfo: ["clinicalMode": true]
        )
    }

    private func startPulseAnimation() {
        // Respect user's reduce motion preference
        if reduceMotion {
            isPulsing = true  // Set state without animation
        } else {
            withAnimation(
                .easeInOut(duration: 1.5)
                .repeatForever(autoreverses: true)
            ) {
                isPulsing = true
            }
        }
    }

    private func requestMicrophonePermission() {
        microphoneError = nil
        isMicrophoneLoading = true

        microphonePermissionTask?.cancel()
        microphonePermissionTask = Task { @MainActor in
            // Ensure loading state is cleared regardless of how Task exits
            defer {
                if !Task.isCancelled {
                    isMicrophoneLoading = false
                }
            }

            do {
                try await permissionService.requestMicrophonePermission()
                guard !Task.isCancelled else { return }
                await refreshPermissions()
            } catch {
                guard !Task.isCancelled else { return }
                microphoneError = "Permission denied. Please grant access in System Settings."
                AppLogger.system.warning("Microphone permission denied")
            }
        }
    }

    private func requestAccessibilityPermission() {
        accessibilityError = nil
        isAccessibilityPolling = true

        accessibilityPermissionTask?.cancel()
        accessibilityPermissionTask = Task { @MainActor in
            // Ensure loading state is cleared regardless of how Task exits
            defer {
                if !Task.isCancelled {
                    isAccessibilityPolling = false
                }
            }

            do {
                try permissionService.requestAccessibilityPermission()
            } catch {
                AppLogger.system.info("Opening System Settings for accessibility permission")
            }

            var grantedViaCallback = false
            await permissionService.pollForAccessibilityPermission(
                interval: 1.0,
                maxDuration: 60.0
            ) {
                // Callback is already @MainActor, no nested Task needed
                self.accessibilityGranted = true
                grantedViaCallback = true
            }

            guard !Task.isCancelled else { return }

            // Check actual permission state instead of relying on callback flag
            // This avoids race conditions between callback invocation and check
            if !accessibilityGranted && !grantedViaCallback {
                accessibilityError = "Permission not granted. Please enable in System Settings."
            }
        }
    }
}

// MARK: - Glass Permission Card

/// Glassmorphism permission status card
private struct GlassPermissionCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let isGranted: Bool
    let isLoading: Bool
    let errorMessage: String?
    let actionLabel: String
    let isFocused: Bool
    let colorScheme: ColorScheme
    let onAction: () -> Void
    let onDismissError: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main card content
            HStack(spacing: 14) {
                // Icon with status glow (decorative)
                ZStack {
                    Circle()
                        .fill(iconBackgroundColor)
                        .frame(width: 44, height: 44)

                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(iconColor)
                }
                .shadow(color: iconGlowColor, radius: 8, x: 0, y: 2)
                .accessibilityHidden(true)

                // Title and subtitle
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text(subtitle)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Status or action button
                statusContent
            }
            .padding(16)

            // Error message row (if present)
            if let errorMessage = errorMessage {
                errorRow(message: errorMessage)
            }
        }
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(cardBorder)
        .shadow(color: shadowColor, radius: 12, x: 0, y: 4)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isGranted)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isLoading)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: errorMessage != nil)
        .animation(.easeInOut(duration: 0.15), value: isFocused)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabelText)
        .accessibilityHint(accessibilityHintText)
    }

    // MARK: - Accessibility

    private var accessibilityLabelText: String {
        if isLoading {
            return "\(title) permission: Checking"
        } else if isGranted {
            return "\(title) permission: Granted"
        } else if errorMessage != nil {
            return "\(title) permission: Not granted. Error"
        } else {
            return "\(title) permission: Not granted"
        }
    }

    private var accessibilityHintText: String {
        if isGranted {
            return ""
        } else if errorMessage != nil {
            return "Double-tap to retry granting \(title) access"
        } else if !isLoading {
            return "Double-tap to grant \(title) access"
        }
        return ""
    }

    // MARK: - Computed Properties

    private var iconColor: Color {
        if errorMessage != nil {
            return Color.errorRed
        } else if isGranted {
            return Color.successGreen
        } else {
            return Color.iconPrimaryAdaptive
        }
    }

    private var iconBackgroundColor: Color {
        if errorMessage != nil {
            return Color.errorRed.opacity(0.12)
        } else if isGranted {
            return Color.successGreen.opacity(0.12)
        } else {
            return Color.selectionBackgroundAdaptive
        }
    }

    private var iconGlowColor: Color {
        if errorMessage != nil {
            return Color.errorRed.opacity(0.15)
        } else if isGranted {
            return Color.successGreen.opacity(0.15)
        } else {
            return Color.cardShadowAdaptive
        }
    }

    private var cardBackground: some View {
        Group {
            if isFocused {
                Color.selectionBackgroundAdaptive
            } else {
                Color.cardBackgroundAdaptive
            }
        }
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 14)
            .stroke(borderColor, lineWidth: isFocused ? 2.5 : 1)
    }

    private var borderColor: Color {
        if isFocused {
            // Use warm amber for focus instead of system blue
            return Color.amberPrimary
        } else if errorMessage != nil {
            return Color.errorRed.opacity(0.4)
        } else if isGranted {
            return Color.successGreen.opacity(0.3)
        } else {
            return Color.cardBorderAdaptive
        }
    }

    private var shadowColor: Color {
        if isFocused {
            // Amber glow when focused
            return Color.amberPrimary.opacity(0.25)
        } else if isGranted {
            return Color.successGreen.opacity(0.1)
        } else if errorMessage != nil {
            return Color.errorRed.opacity(0.1)
        } else {
            return Color.cardShadowAdaptive
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var statusContent: some View {
        if isLoading {
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Checking...")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.textTertiaryAdaptive)
            }
            .accessibilityLabel("Checking permission status")
        } else if isGranted {
            Label("Ready", systemImage: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.successGreen)
        } else if errorMessage != nil {
            Button(action: onAction) {
                HStack(spacing: 4) {
                    Text("Retry")
                    Image(systemName: "arrow.clockwise")
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.iconPrimaryAdaptive)
            }
            .buttonStyle(.plain)
        } else {
            Button(action: onAction) {
                HStack(spacing: 4) {
                    Text(actionLabel)
                    Image(systemName: "arrow.right")
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: colorScheme == .dark
                                    ? [.amberLight, .amberPrimary]
                                    : [Color(hex: "C4891A"), Color(hex: "9A6A10")],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .shadow(color: Color.cardShadowAdaptive, radius: 4, x: 0, y: 2)
            }
            .buttonStyle(.plain)
        }
    }

    private func errorRow(message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.errorRed)

            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Color.errorRed)
                .lineLimit(2)

            Spacer()

            Button {
                onDismissError()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss error")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.errorRed.opacity(0.1))
    }
}

// MARK: - Previews

#Preview("Home Section - All Granted") {
    HomeSection(
        settingsService: SettingsService(),
        permissionService: PermissionService()
    )
    .frame(width: 600, height: 780)
}

#Preview("Home Section - Dark Mode") {
    HomeSection(
        settingsService: SettingsService(),
        permissionService: PermissionService()
    )
    .frame(width: 600, height: 780)
    .preferredColorScheme(.dark)
}
