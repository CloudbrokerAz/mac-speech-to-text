// ReviewScreen.swift
// macOS Local Speech-to-Text Application
//
// Primary review + edit surface for a generated clinical note (#13).
// Layout is locked per the EPIC #1 wireframe: frosted header (patient +
// draft warning), two-column body (SOAP editor on the left, manipulations
// checklist + excluded drawer on the right), action bar (View raw
// transcript / Cancel / Export to Cliniko).
//
// Adheres to Warm Minimalism: `.ultraThinMaterial`, amber accents from
// `Color+Theme.swift`, spring `(0.5, 0.7)` animations, minimal chrome.
//
// PHI: every SOAP field, manipulation choice, excluded snippet, and
// transcript line is patient data. View stays purely presentational —
// all logging is owned by `ReviewViewModel`. See
// `.claude/references/phi-handling.md`.

import SwiftUI

/// Root SwiftUI surface for `ReviewWindow`. Built from a pre-instantiated
/// `ReviewViewModel` (the actor-existential mitigation pattern documented
/// in `.claude/references/concurrency.md` §1).
struct ReviewScreen: View {

    @Bindable var viewModel: ReviewViewModel

    /// Shared focus state across the four SOAP editors. Powers ⌘1–⌘4
    /// keyboard navigation (each of those shortcuts writes the matching
    /// field into this state via the hidden command-buttons block).
    @FocusState private var focusedField: SOAPField?

    var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                header

                bodyPanel
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)

                actionBar
            }

            // Hidden buttons that expose the keyboard shortcuts. Buttons
            // are the only `View` form that registers a shortcut without
            // also taking visible space — and being inside the visible
            // hierarchy is required for the shortcut to fire (off-screen
            // buttons are ignored). `frame(0,0)` + `hidden()` is the
            // documented pattern.
            shortcutSink
        }
        .frame(minWidth: 880, minHeight: 560)
        .sheet(isPresented: $viewModel.isRawTranscriptSheetOpen) {
            RawTranscriptSheet(
                transcript: viewModel.transcript,
                onDismiss: { viewModel.dismissRawTranscript() }
            )
        }
        .onAppear {
            // Ensure the practitioner can immediately start editing the
            // most-used field without an extra click.
            focusedField = .subjective
            viewModel.noteFieldFocused(.subjective)
        }
        .accessibilityIdentifier("reviewScreen")
    }

    // MARK: - Background

    private var background: some View {
        // Subtle adaptive background so the panes have a parent surface
        // distinct from the SwiftUI window's translucent backdrop.
        Color.secondaryBackgroundAdaptive
            .ignoresSafeArea()
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Clinical Notes Review")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .accessibilityAddTraits(.isHeader)

                Text(headerSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            draftBadge
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.subtleBorderAdaptive)
                .frame(height: 1)
        }
        .accessibilityIdentifier("reviewScreen.header")
    }

    private var headerSubtitle: String {
        viewModel.hasDraft
            ? "Review and edit the AI-drafted note before exporting."
            : "No draft yet — compose the note from the raw transcript."
    }

    private var draftBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.amberBright)
            Text("Draft")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(Color.amberLight.opacity(0.4))
        )
        .accessibilityIdentifier("reviewScreen.draftBadge")
    }

    // MARK: - Body

    private var bodyPanel: some View {
        HStack(alignment: .top, spacing: 16) {
            soapColumn
                .frame(maxWidth: .infinity, alignment: .leading)

            sidebarColumn
                .frame(width: 280)
        }
    }

    // MARK: SOAP column

    private var soapColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(SOAPField.allCases, id: \.self) { field in
                    SOAPSectionEditor(
                        field: field,
                        text: viewModel.binding(for: field),
                        focusBinding: $focusedField,
                        onFocus: { viewModel.noteFieldFocused(field) }
                    )
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.cardBackgroundAdaptive)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.subtleBorderAdaptive, lineWidth: 1)
            )
            .shadow(color: Color.cardShadowAdaptive, radius: 6, x: 0, y: 2)
        }
        .accessibilityIdentifier("reviewScreen.soapColumn")
    }

    // MARK: Sidebar column

    private var sidebarColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            ManipulationsChecklist(viewModel: viewModel)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.cardBackgroundAdaptive)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.subtleBorderAdaptive, lineWidth: 1)
                )

            ExcludedContentDrawer(viewModel: viewModel)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.subtleBorderAdaptive, lineWidth: 1)
                )
        }
        .accessibilityIdentifier("reviewScreen.sidebarColumn")
    }

    // MARK: - Action bar

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button {
                viewModel.presentRawTranscript()
            } label: {
                Label("View raw transcript", systemImage: "doc.text.magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .disabled(!viewModel.hasTranscript)
            .accessibilityIdentifier("reviewScreen.actions.viewRawTranscript")

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.errorRed)
                    .lineLimit(1)
                    .accessibilityIdentifier("reviewScreen.errorBanner")
            }

            Spacer()

            Button("Cancel") {
                viewModel.cancelReview()
            }
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("reviewScreen.actions.cancel")

            Button {
                viewModel.triggerExport()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.forward.app.fill")
                    Text("Export to Cliniko")
                }
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.amberPrimary)
            .disabled(!viewModel.canExport)
            .accessibilityIdentifier("reviewScreen.actions.export")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.subtleBorderAdaptive)
                .frame(height: 1)
        }
        .accessibilityIdentifier("reviewScreen.actionBar")
    }

    // MARK: - Keyboard shortcut sink

    /// Hidden command buttons that own the ⌘1–⌘4 + ⌘E shortcuts. Each
    /// shortcut focuses the matching SOAP editor (or triggers Export).
    /// Kept as a separate group so the visible chrome above stays
    /// shortcut-free.
    private var shortcutSink: some View {
        Group {
            ForEach(SOAPField.allCases, id: \.self) { field in
                Button("Focus \(field.displayName)") {
                    // SOAPSectionEditor's `onChange(of: focusBinding.wrappedValue)`
                    // will invoke `viewModel.noteFieldFocused(field)` when this
                    // assignment lands, so we deliberately do not double-fire it.
                    focusedField = field
                }
                .keyboardShortcut(shortcutKey(for: field), modifiers: [.command])
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
            }

            Button("Export") {
                viewModel.triggerExport()
            }
            .keyboardShortcut("e", modifiers: [.command])
            .frame(width: 0, height: 0)
            .opacity(0)
            .disabled(!viewModel.canExport)
            .accessibilityHidden(true)
        }
    }

    private func shortcutKey(for field: SOAPField) -> KeyEquivalent {
        switch field {
        case .subjective: return "1"
        case .objective: return "2"
        case .assessment: return "3"
        case .plan: return "4"
        }
    }
}

// MARK: - Preview

#Preview("Review Screen") {
    let store = SessionStore()
    var session = RecordingSession(language: "en", state: .completed)
    session.transcribedText = "Patient reports R-neck pain x 3/52, worse with rotation. Cervical screening normal. Plan diversified HVLA C5-C6 + Activator T2-T4."
    store.start(from: session)
    var notes = StructuredNotes()
    notes.subjective = "Pt reports R-neck pain x 3/52."
    notes.objective = "C5/C6 restriction, hypertonic R upper trap."
    notes.assessment = "Mechanical cervical dysfunction."
    notes.plan = "HVLA C5-C6, Activator T2-T4. Re-eval next visit."
    notes.excluded = ["Weather chat at start of consult.", "Patient mentioned kids and dog.", "Brief parking discussion."]
    notes.selectedManipulationIDs = ["diversified_hvla", "activator"]
    store.setDraftNotes(notes)

    let manipulations = ManipulationsRepository(all: [
        Manipulation(id: "diversified_hvla", displayName: "Diversified HVLA", clinikoCode: nil),
        Manipulation(id: "gonstead", displayName: "Gonstead", clinikoCode: nil),
        Manipulation(id: "activator", displayName: "Activator", clinikoCode: nil),
        Manipulation(id: "thompson", displayName: "Thompson", clinikoCode: nil),
        Manipulation(id: "sot", displayName: "SOT", clinikoCode: nil)
    ])

    return ReviewScreen(viewModel: ReviewViewModel(
        sessionStore: store,
        manipulations: manipulations
    ))
    .frame(width: 1100, height: 720)
}
