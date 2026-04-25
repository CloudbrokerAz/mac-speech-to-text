// RawTranscriptSheet.swift
// macOS Local Speech-to-Text Application
//
// Read-only sheet that surfaces the unmodified consultation transcript.
// Triggered from `ReviewScreen` via "View raw transcript" — used both
// as a sanity-check for the practitioner during edit, and as the
// primary surface in the LLM-fallback path where `draftNotes` is empty.
//
// PHI: every visible character is patient data. The view is purely
// presentational and contains no logging or external send paths.

import SwiftUI

struct RawTranscriptSheet: View {
    let transcript: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            ScrollView {
                Text(displayedText)
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("reviewScreen.rawTranscript.body")
            }
            .frame(minHeight: 320)
        }
        .frame(minWidth: 520, minHeight: 420)
        .background(.background)
        .accessibilityIdentifier("reviewScreen.rawTranscript")
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Raw transcript")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .accessibilityAddTraits(.isHeader)
                Text("Read-only — close this sheet to keep editing the SOAP note.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Close", action: onDismiss)
                .keyboardShortcut(.escape)
                .accessibilityIdentifier("reviewScreen.rawTranscript.close")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    /// Show a placeholder if the transcript is empty so the practitioner
    /// is not staring at a blank pane.
    private var displayedText: String {
        transcript.isEmpty
            ? "(No transcript captured for this session.)"
            : transcript
    }
}
