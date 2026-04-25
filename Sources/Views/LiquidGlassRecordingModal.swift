// LiquidGlassRecordingModal.swift
// macOS Local Speech-to-Text Application
//
// A stunning liquid glass recording modal with prismatic effects,
// aurora waveforms, and organic morphing animations.
// Design: "Living Glass" - the interface breathes and responds to audio.

import OSLog
import SwiftUI

/// LiquidGlassRecordingModal - Premium recording interface with liquid glass aesthetics
struct LiquidGlassRecordingModal: View {
    // MARK: - Environment

    @Environment(\.dismiss) private var dismiss

    // MARK: - State

    @State var viewModel: RecordingViewModel
    @State private var showError: Bool = false
    @State private var isVisible: Bool = false
    @State private var isDismissing: Bool = false
    @State private var recordingTaskId: UUID?
    @State private var dismissTaskId: UUID?
    @State private var glassTime: Double = 0

    // MARK: - Initialization

    init(viewModel: RecordingViewModel = RecordingViewModel()) {
        self._viewModel = State(initialValue: viewModel)
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            // Ambient background with subtle blur
            ambientBackground

            // Main liquid glass modal
            liquidGlassModal
                .scaleEffect(isVisible ? 1.0 : 0.85)
                .opacity(isVisible ? 1.0 : 0.0)

            // Safety Disclaimer overlay (#12). Covers the modal so the
            // close button and other actions are blocked while the doctor
            // confirms the "drafting assistant, not a diagnostic tool"
            // notice. The disclaimer view enforces its own single-action
            // dismissal contract.
            if viewModel.showSafetyDisclaimer {
                SafetyDisclaimerView(
                    onAcknowledge: handleSafetyDisclaimerAcknowledged
                )
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                .zIndex(1)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.75)) {
                isVisible = true
            }
            withAnimation(.linear(duration: 30).repeatForever(autoreverses: false)) {
                glassTime = 360
            }
            recordingTaskId = UUID()
        }
        .task(id: recordingTaskId) {
            guard recordingTaskId != nil else { return }
            do {
                try await viewModel.startRecording()
            } catch {
                guard !Task.isCancelled else { return }
                viewModel.errorMessage = "Failed to start recording: \(error.localizedDescription)"
                AppLogger.viewModel.error("startRecording failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        .task(id: dismissTaskId) {
            guard dismissTaskId != nil else { return }
            let dismissAction = dismiss
            await viewModel.cancelRecording()
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            dismissAction()
        }
        .onDisappear {
            recordingTaskId = nil
            dismissTaskId = nil
            // If the window closes while the Safety Disclaimer overlay
            // (#12) is still up — e.g. AppKit teardown or a Cmd+W-equivalent
            // bypass we missed — log structurally so the recording loss is
            // visible in sysdiagnose. PHI rule: length only, never the
            // transcript body.
            if viewModel.showSafetyDisclaimer {
                AppLogger.viewModel.info(
                    "Recording modal dismissed while safety disclaimer was up — discarding transcript length=\(viewModel.transcribedText.count, privacy: .public)"
                )
            }
            guard !isDismissing else { return }
            Task.detached { @MainActor in
                await viewModel.cancelRecording()
            }
        }
        .onKeyPress(.escape) {
            // Block dismissal via ESC while the Safety Disclaimer (#12) is
            // showing — the disclaimer enforces a single "I understand,
            // continue" path and must not be dismissable by keyboard.
            guard !viewModel.showSafetyDisclaimer else { return .handled }
            handleDismiss()
            return .handled
        }
        .onChange(of: viewModel.errorMessage) { _, newValue in
            showError = newValue != nil
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: viewModel.showSafetyDisclaimer)
    }

    // MARK: - Ambient Background

    private var ambientBackground: some View {
        Color.black.opacity(0.01)
            .ignoresSafeArea()
            .onTapGesture {
                // Block ambient-tap dismissal while the Safety Disclaimer
                // (#12) is showing. The disclaimer must not be dismissable
                // by clicking outside it; only its single button advances.
                guard !viewModel.showSafetyDisclaimer else { return }
                handleDismiss()
            }
    }

    // MARK: - Liquid Glass Modal

    private var liquidGlassModal: some View {
        VStack(spacing: 0) {
            // Header
            headerSection
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)

            // Central visualization
            centralVisualization
                .padding(.horizontal, 16)

            // Status section
            statusSection
                .padding(.horizontal, 20)
                .padding(.top, 16)

            // Permission prompts
            permissionPrompts
                .padding(.horizontal, 16)

            // Error display
            if let errorMessage = viewModel.errorMessage, showError {
                errorSection(message: errorMessage)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }

            // Action buttons
            actionSection
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 20)
        }
        .frame(width: 320)
        .background(glassBackground)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(glassOverlays)
        .shadow(color: Color.liquidGlassShadow.opacity(0.4), radius: 40, x: 0, y: 20)
        .shadow(color: (viewModel.isRecording ? Color.liquidRecordingCore : Color.liquidPrismaticBlue).opacity(0.2), radius: 60, x: 0, y: 30)
        // DEBUG: Bright border to confirm this modal is loading
        .overlay(
            RoundedRectangle(cornerRadius: 28)
                .stroke(Color.green, lineWidth: 5)
        )
    }

    // MARK: - Header Section

    private var headerSection: some View {
        HStack(spacing: 12) {
            // Recording indicator orb
            ZStack {
                // Outer glow
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                (viewModel.isRecording ? Color.liquidRecordingCore : Color.liquidPrismaticBlue).opacity(0.4),
                                .clear
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: 18
                        )
                    )
                    .frame(width: 36, height: 36)

                // Core orb
                Circle()
                    .fill(
                        RadialGradient(
                            colors: viewModel.isRecording ? [
                                Color.liquidRecordingCore,
                                Color.liquidRecordingMid
                            ] : [
                                Color.liquidPrismaticBlue,
                                Color.liquidPrismaticPurple
                            ],
                            center: UnitPoint(x: 0.3, y: 0.3),
                            startRadius: 0,
                            endRadius: 10
                        )
                    )
                    .frame(width: 14, height: 14)

                // Inner highlight
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [.white.opacity(0.8), .clear],
                            center: UnitPoint(x: 0.3, y: 0.3),
                            startRadius: 0,
                            endRadius: 4
                        )
                    )
                    .frame(width: 6, height: 6)
                    .offset(x: -2, y: -2)
            }
            .animation(.easeInOut(duration: 0.3), value: viewModel.isRecording)

            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)

                Text(statusSubtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Close button
            Button(action: handleDismiss) {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 28, height: 28)

                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("closeButton")
            .accessibilityLabel("Close")
        }
        .accessibilityIdentifier("recordingHeader")
    }

    // MARK: - Central Visualization

    private var centralVisualization: some View {
        ZStack {
            // Aurora waveform background
            AuroraWaveform(
                audioLevel: Float(viewModel.audioLevel),
                isRecording: viewModel.isRecording
            )
            .frame(height: 90)
            .mask(
                LinearGradient(
                    colors: [.clear, .white, .white, .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )

            // Central morphing orb (optional - comment out if too busy)
            if viewModel.isRecording {
                LiquidOrbWaveform(
                    audioLevel: Float(viewModel.audioLevel),
                    isRecording: true
                )
                .frame(width: 70, height: 70)
                .opacity(0.6)
            }
        }
        .frame(height: 100)
        .accessibilityIdentifier("waveformView")
        .accessibilityLabel("Audio waveform")
        .accessibilityValue("\(Int(viewModel.audioLevel * 100))% audio level")
    }

    // MARK: - Status Section

    private var statusSection: some View {
        Group {
            if viewModel.isTranscribing {
                HStack(spacing: 8) {
                    // Prismatic spinner
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(Color.liquidPrismaticBlue)

                    Text("Transcribing...")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            } else if viewModel.isInserting {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(Color.liquidPrismaticGreen)

                    Text("Inserting...")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            } else if !viewModel.transcribedText.isEmpty {
                Text(viewModel.transcribedText)
                    .font(.system(size: 14, weight: .regular, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            } else if viewModel.isRecording {
                Text("Listening...")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.liquidPrismaticCyan.opacity(0.8))
            } else {
                Text("Ready")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(minHeight: 28)
    }

    // MARK: - Permission Prompts

    @ViewBuilder
    private var permissionPrompts: some View {
        if viewModel.showMicrophonePrompt {
            InlineMicrophonePrompt(
                onOpenSettings: { viewModel.openMicrophoneSettings() },
                onCancel: { viewModel.dismissMicrophonePrompt() }
            )
            .transition(.asymmetric(
                insertion: .scale(scale: 0.9).combined(with: .opacity),
                removal: .opacity
            ))
            .padding(.top, 12)
        }

        if viewModel.showAccessibilityPrompt {
            InlineAccessibilityPrompt(
                onEnableAutoPaste: {
                    viewModel.openAccessibilitySettings()
                    viewModel.dismissAccessibilityPrompt()
                },
                onUseClipboardOnly: { viewModel.setClipboardOnlyMode() }
            )
            .transition(.asymmetric(
                insertion: .scale(scale: 0.9).combined(with: .opacity),
                removal: .opacity
            ))
            .padding(.top, 12)
        }
    }

    // MARK: - Error Section

    private func errorSection(message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.liquidRecordingCore)

            Text(message)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Color.liquidRecordingCore)
                .lineLimit(2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.liquidRecordingCore.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.liquidRecordingCore.opacity(0.2), lineWidth: 1)
                )
        )
        .transition(.scale(scale: 0.9).combined(with: .opacity))
        .accessibilityIdentifier("errorMessage")
    }

    // MARK: - Action Section

    private var actionSection: some View {
        HStack(spacing: 10) {
            if viewModel.isRecording {
                // Done button - prismatic gradient
                Button {
                    Task {
                        do {
                            try await viewModel.stopRecording()
                            try? await Task.sleep(nanoseconds: 700_000_000)
                            handleDismiss()
                        } catch {
                            viewModel.errorMessage = error.localizedDescription
                            AppLogger.viewModel.error("stopRecording failed: \(error.localizedDescription, privacy: .public)")
                        }
                    }
                } label: {
                    Text("Done")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            LinearGradient(
                                colors: [Color.liquidPrismaticBlue, Color.liquidPrismaticPurple],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .shadow(color: Color.liquidPrismaticBlue.opacity(0.4), radius: 8, y: 4)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return)
                .accessibilityIdentifier("stopRecordingButton")

                // Cancel button - glass style
                Button {
                    handleDismiss()
                } label: {
                    Text("Cancel")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.white.opacity(0.1), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("cancelButton")

            } else if viewModel.isTranscribing || viewModel.isInserting {
                // Processing state - no buttons
                EmptyView()

            } else if !viewModel.transcribedText.isEmpty {
                if viewModel.isClinicalNotesEnabled {
                    // Clinical Notes Mode (#11): show "Generate Notes" + "Done"
                    // instead of auto-dismissing. Tap surfaces the transcript
                    // to whoever listens for `.clinicalNotesGenerateRequested`
                    // (ReviewScreen presenter wires up in #13).
                    Button {
                        handleGenerateNotes()
                    } label: {
                        Text("Generate Notes")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                LinearGradient(
                                    colors: [Color.liquidPrismaticGreen, Color.liquidPrismaticCyan],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .shadow(color: Color.liquidPrismaticGreen.opacity(0.4), radius: 8, y: 4)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return)
                    .accessibilityIdentifier("generateNotesButton")

                    Button {
                        handleDismiss()
                    } label: {
                        Text("Done")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("doneAfterTranscriptionButton")
                } else {
                    // Default: success indicator + auto-dismiss after 0.9s
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [Color.liquidPrismaticGreen, Color.liquidPrismaticCyan],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )

                        Text(viewModel.lastTranscriptionCopiedToClipboard ? "Copied!" : "Inserted!")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [Color.liquidPrismaticGreen, Color.liquidPrismaticCyan],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                    }
                    .onAppear {
                        Task {
                            try? await Task.sleep(nanoseconds: 900_000_000)
                            handleDismiss()
                        }
                    }
                }

            } else if viewModel.errorMessage != nil {
                Button {
                    handleDismiss()
                } label: {
                    Text("Dismiss")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("cancelButton")
            }
        }
        .accessibilityIdentifier("actionButtons")
    }

    // MARK: - Glass Background

    private var glassBackground: some View {
        ZStack {
            // Frosted glass base
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.ultraThinMaterial)

            // Prismatic shimmer overlay
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.liquidPrismaticPink.opacity(0.08),
                            Color.liquidPrismaticBlue.opacity(0.06),
                            Color.liquidPrismaticCyan.opacity(0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            // Caustic light dance
            CausticMesh(time: glassTime, audioLevel: Float(viewModel.audioLevel))
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .opacity(0.25)

            // Top highlight
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.15),
                            Color.clear
                        ],
                        startPoint: .top,
                        endPoint: .center
                    )
                )
        }
    }

    // MARK: - Glass Overlays

    private var glassOverlays: some View {
        ZStack {
            // Inner highlight rim
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.4),
                            .white.opacity(0.1),
                            .clear,
                            .white.opacity(0.05)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.5
                )

            // Prismatic edge glow
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(
                    AngularGradient(
                        colors: [
                            Color.liquidPrismaticPink.opacity(0.25),
                            Color.liquidPrismaticBlue.opacity(0.25),
                            Color.liquidPrismaticCyan.opacity(0.2),
                            Color.liquidPrismaticGreen.opacity(0.15),
                            Color.liquidPrismaticYellow.opacity(0.2),
                            Color.liquidPrismaticPink.opacity(0.25)
                        ],
                        center: .center,
                        angle: .degrees(glassTime * 0.5)
                    ),
                    lineWidth: 2
                )
                .blur(radius: 3)

            // Shimmer highlight
            ShimmerEffect()
                .opacity(0.15)
        }
    }

    // MARK: - Computed Properties

    private var statusTitle: String {
        if viewModel.isRecording {
            return "Recording"
        } else if viewModel.isTranscribing {
            return "Processing"
        } else if viewModel.isInserting {
            return "Inserting"
        } else if !viewModel.transcribedText.isEmpty {
            return "Complete"
        } else {
            return "Ready"
        }
    }

    private var statusSubtitle: String {
        if viewModel.isRecording {
            return "Speak now..."
        } else if viewModel.isTranscribing {
            return "Converting speech"
        } else if viewModel.isInserting {
            return "Pasting text"
        } else if !viewModel.transcribedText.isEmpty {
            return "Success"
        } else {
            return "Preparing..."
        }
    }

    // MARK: - Private Methods

    private func handleDismiss() {
        // Defence-in-depth (#12): the Safety Disclaimer overlay's
        // full-bleed dimmer hit-test-blocks the close button today, but a
        // future ZStack refactor could let dismissal through. The
        // disclaimer enforces a single "I understand, continue" path, so
        // refuse to dismiss while it's up.
        guard !viewModel.showSafetyDisclaimer else { return }
        guard !isDismissing else { return }
        isDismissing = true
        recordingTaskId = nil

        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            isVisible = false
        }

        dismissTaskId = UUID()
    }

    /// Hand the just-finished transcript to the Clinical Notes pipeline
    /// (#13's ReviewScreen presenter listens). Posting via `NotificationCenter`
    /// keeps the modal decoupled from `AppState` and lets #13 land its
    /// presenter in one place without further changes here.
    ///
    /// Until the ReviewScreen presenter lands in #13, this post has no
    /// observers and the modal dismisses with the transcript only present on
    /// `RecordingViewModel.transcribedText` (cleared on next start). When #13
    /// opens the review screen it must also defensively re-check Cliniko
    /// credential presence before allowing export — the toggle's disabled
    /// state can desynchronise from on-disk credential state if a settings
    /// save fails on the credential-removal auto-disable path. #14's export
    /// flow is the consumer-side enforcement point for that invariant.
    ///
    /// Safety Disclaimer gate (#12): on the first invocation of a fresh
    /// Clinical Notes Mode session, the doctor must acknowledge the
    /// "drafting assistant, not a diagnostic tool" notice. The
    /// acknowledgement handler calls `postGenerateNotesAndDismiss(transcript:)`
    /// directly on success — no re-entrancy here, so a save failure can't
    /// silently re-present the overlay in the same gesture.
    private func handleGenerateNotes() {
        let transcript = viewModel.transcribedText
        guard !transcript.isEmpty else {
            // Defence-in-depth: parent `if !viewModel.transcribedText.isEmpty`
            // already gates rendering of this branch. If we reach here, the
            // invariant is broken and a developer should notice.
            AppLogger.viewModel.warning(
                "handleGenerateNotes called with empty transcript — unexpected"
            )
            return
        }

        // Safety Disclaimer (#12): present the one-time acknowledgement
        // overlay before surfacing the transcript to any downstream listener.
        // `handleSafetyDisclaimerAcknowledged` continues the flow on success.
        guard viewModel.isSafetyDisclaimerAcknowledged else {
            AppLogger.viewModel.info(
                "Safety disclaimer required — presenting before clinicalNotesGenerateRequested post"
            )
            viewModel.presentSafetyDisclaimer()
            return
        }

        postGenerateNotesAndDismiss(transcript: transcript)
    }

    /// Post the transcript to the Clinical Notes pipeline and dismiss the
    /// modal. Extracted so both the ack-already-true fast path and the
    /// post-acknowledge bridge can call it directly without re-entering
    /// the gating logic. PHI rule: length only — never the transcript body.
    private func postGenerateNotesAndDismiss(transcript: String) {
        // The empty-transcript guard in `handleGenerateNotes` is
        // structurally upstream of every caller; defensively re-check so
        // a future caller can't post an empty payload.
        guard !transcript.isEmpty else {
            AppLogger.viewModel.warning(
                "postGenerateNotesAndDismiss called with empty transcript — refusing to post"
            )
            return
        }
        AppLogger.viewModel.info(
            "clinicalNotesGenerateRequested posted length=\(transcript.count, privacy: .public)"
        )
        NotificationCenter.default.post(
            name: .clinicalNotesGenerateRequested,
            object: nil,
            userInfo: ["transcript": transcript]
        )
        handleDismiss()
    }

    /// Bridge between the disclaimer overlay and the Clinical Notes flow.
    /// Persists the ack flag and proceeds to post + dismiss directly on
    /// success. On persistence failure the view model surfaces a banner
    /// via `errorMessage`, dismisses the overlay so the banner is visible,
    /// and we abort the flow without posting.
    ///
    /// Single-shot: a rapid double-tap (or Return-Return on the
    /// `borderedProminent` button) could enqueue two actions before
    /// SwiftUI removes the disclaimer from the tree. The disclaimer's
    /// own `hasAcknowledged` guard absorbs the second `onAcknowledge`
    /// invocation; this `isDismissing` check is the modal-side belt to
    /// that braces, ensuring no duplicate `clinicalNotesGenerateRequested`
    /// post even if the view-side guard ever regresses.
    private func handleSafetyDisclaimerAcknowledged() {
        guard !isDismissing else { return }
        let transcript = viewModel.transcribedText
        guard viewModel.acknowledgeSafetyDisclaimer() else {
            AppLogger.viewModel.warning(
                "Safety disclaimer ack failed to persist — aborting clinical-notes post"
            )
            return
        }
        postGenerateNotesAndDismiss(transcript: transcript)
    }
}

// MARK: - Previews

#Preview("Liquid Glass Recording") {
    LiquidGlassRecordingModal()
        .preferredColorScheme(.dark)
}

#Preview("Light Mode") {
    LiquidGlassRecordingModal()
        .preferredColorScheme(.light)
}
