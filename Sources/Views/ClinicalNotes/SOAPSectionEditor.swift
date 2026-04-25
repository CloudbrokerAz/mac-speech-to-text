// SOAPSectionEditor.swift
// macOS Local Speech-to-Text Application
//
// Single SOAP section editor used by `ReviewScreen` (#13). Renders a
// section header, an editable `TextEditor` bound to `ReviewViewModel`,
// and propagates focus back to the VM so re-add routing can find the
// last-touched field.
//
// PHI: the bound text is patient data. The view is purely
// presentational — no logging, no telemetry. See
// `.claude/references/phi-handling.md`.

import SwiftUI

/// One editable SOAP section. The host (`ReviewScreen`) owns the
/// `@FocusState` and binds it through; this keeps a single SwiftUI
/// focus chain across all four sections so ⌘1–⌘4 can route focus
/// without each editor maintaining its own state.
struct SOAPSectionEditor: View {

    let field: SOAPField

    /// Binding into the practitioner-edited string. Reads / writes hop
    /// through `SessionStore` via `ReviewViewModel.binding(for:)`.
    @Binding var text: String

    /// Shared focus chain across the four SOAP fields.
    var focusBinding: FocusState<SOAPField?>.Binding

    /// Invoked when this editor takes focus. The VM uses the timestamp to
    /// route re-added excluded entries to the most recently focused
    /// field.
    let onFocus: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader

            TextEditor(text: $text)
                .font(.system(size: 13))
                .focused(focusBinding, equals: field)
                .onChange(of: focusBinding.wrappedValue) { _, newValue in
                    if newValue == field { onFocus() }
                }
                .padding(8)
                .frame(minHeight: 96)
                .background(.background.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(borderColor, lineWidth: 1)
                )
                .accessibilityIdentifier("reviewScreen.soap.\(field.accessibilityID).editor")
        }
        .accessibilityIdentifier("reviewScreen.soap.\(field.accessibilityID)")
    }

    private var sectionHeader: some View {
        HStack(spacing: 8) {
            Text(field.displayName.uppercased())
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(Color.iconPrimaryAdaptive)

            Spacer()

            // Subtle keyboard-shortcut hint, mirrors the SettingsView /
            // recording modal idiom — small, secondary, never the focus.
            Text(shortcutHint)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
    }

    private var shortcutHint: String {
        switch field {
        case .subjective: return "⌘1"
        case .objective: return "⌘2"
        case .assessment: return "⌘3"
        case .plan: return "⌘4"
        }
    }

    private var borderColor: Color {
        focusBinding.wrappedValue == field
            ? Color.amberPrimary.opacity(0.5)
            : Color.subtleBorderAdaptive
    }
}

// MARK: - Preview

#Preview("SOAPSectionEditor") {
    PreviewHost()
        .padding()
        .frame(width: 480, height: 240)
}

private struct PreviewHost: View {
    @State private var text = "Patient reports R-neck pain x 3/52, worse with cervical rotation."
    @FocusState private var focused: SOAPField?

    var body: some View {
        SOAPSectionEditor(
            field: .subjective,
            text: $text,
            focusBinding: $focused,
            onFocus: {}
        )
    }
}
