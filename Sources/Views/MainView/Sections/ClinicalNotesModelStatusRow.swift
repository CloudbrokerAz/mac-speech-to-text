// ClinicalNotesModelStatusRow.swift
// macOS Local Speech-to-Text Application
//
// Issue #104 (Deliverable A) — Settings UI surface for the Gemma 4 model
// download lifecycle. Lives inside `ClinicalNotesSection` between the
// connection-status card and the API-key block. PHI-free — only model
// bytes / directory / state are surfaced. See
// `.claude/references/mlx-lifecycle.md`.

import SwiftUI

/// Row that surfaces Gemma 4 download state inside `ClinicalNotesSection`.
///
/// Shape: leading icon + name/size header + state pill on the right; an
/// optional progress bar (only while `.downloading`); a short caption
/// row (model directory) when `.ready`; and a trailing actions cluster
/// driven by the current state.
///
/// Confirmation alerts gate the destructive / bandwidth-heavy actions —
/// a 5+ GB download, a directory removal, and a re-download all cost
/// the user's network or disk and warrant an "are you sure" prompt.
struct ClinicalNotesModelStatusRow: View {
    @Bindable var viewModel: ClinicalNotesModelStatusViewModel

    @State private var showDownloadConfirm: Bool = false
    @State private var showRemoveConfirm: Bool = false
    @State private var showRedownloadConfirm: Bool = false

    private static let modelDisplayName = "Gemma 4 E4B-IT (MLX 4-bit)"

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.warmAmber)
                    .frame(width: 28)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("\(Self.modelDisplayName) — \(formattedSize)")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Local LLM that turns your transcript into structured SOAP notes.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                statePill
            }

            if case .downloading = viewModel.state {
                progressBar
            }

            if isReady, let url = viewModel.modelDirectoryURL {
                diskUsageRow(url: url)
            }

            actionButtons
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("clinicalNotesModelStatusRow")
        .alert("Download Gemma 4 model?", isPresented: $showDownloadConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Download") {
                Task { await viewModel.onDownload() }
            }
        } message: {
            Text("This will download \(formattedSize) to ~/Library/Application Support/. The download runs once; subsequent launches reuse the cached model.")
        }
        .alert("Remove Gemma 4 model?", isPresented: $showRemoveConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                Task { await viewModel.onRemove() }
            }
        } message: {
            Text("This deletes \(formattedSize) of model files from this Mac. You'll need to re-download to use Clinical Notes Mode again.")
        }
        .alert("Re-download Gemma 4 model?", isPresented: $showRedownloadConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Re-download") {
                Task {
                    await viewModel.onRemove()
                    // If the removal failed (e.g. mmap holds the directory,
                    // permissions, or the in-flight task didn't fully unwind)
                    // the state lands in `.failed`, not `.idle`. Skipping the
                    // re-download in that case means the user sees the
                    // honest "Failed" state and can retry from there, instead
                    // of a silent "Ready" backed by the original (still
                    // on-disk) bytes (silent-failure-hunter M3).
                    guard case .idle = viewModel.state else { return }
                    await viewModel.onDownload()
                }
            }
        } message: {
            Text("This will remove the existing \(formattedSize) of model files and download them again.")
        }
    }

    // MARK: - State pill

    private var statePill: some View {
        Text(pillCopy)
            .font(.caption)
            .fontWeight(.medium)
            .foregroundStyle(pillTint)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(pillTint.opacity(0.15))
            .clipShape(Capsule())
            .accessibilityIdentifier("clinicalNotesModelStatusRow.statePill")
    }

    private var pillCopy: String {
        switch viewModel.state {
        case .idle:
            return "Not downloaded"
        case .downloading:
            return "Downloading \(Int((viewModel.progress * 100).rounded()))%"
        case .verified:
            return "Verifying"
        case .ready:
            return "Ready"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        }
    }

    private var pillTint: Color {
        switch viewModel.state {
        case .ready:
            return Color.successGreen
        case .failed:
            return Color.errorRed
        case .downloading, .verified:
            return Color.warmAmber
        case .idle, .cancelled:
            return Color.secondary
        }
    }

    // MARK: - Progress bar

    private var progressBar: some View {
        ProgressView(value: viewModel.progress)
            .progressViewStyle(.linear)
            .tint(Color.warmAmber)
            .accessibilityIdentifier("clinicalNotesModelStatusRow.progressBar")
            .accessibilityLabel("Downloading model, \(Int((viewModel.progress * 100).rounded())) percent complete")
    }

    // MARK: - Disk usage caption

    private func diskUsageRow(url: URL) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "externaldrive")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            // Abbreviate the user-home path so screen-share scenarios
            // don't leak the macOS username (which is often the
            // practitioner's name). `~/Library/...` reads cleaner anyway.
            // No log emission — this is a UI-only surface.
            Text("\(formattedSize) at \(NSString(string: url.path).abbreviatingWithTildeInPath)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .accessibilityIdentifier("clinicalNotesModelStatusRow.diskUsageRow")
    }

    // MARK: - Action buttons

    @ViewBuilder
    private var actionButtons: some View {
        switch viewModel.state {
        case .idle, .cancelled:
            HStack {
                Spacer()
                Button {
                    showDownloadConfirm = true
                } label: {
                    Label("Download model", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.warmAmber)
                .accessibilityIdentifier("clinicalNotesModelStatusRow.actionButton")
            }
        case .downloading, .verified:
            HStack {
                Spacer()
                Button(role: .destructive) {
                    Task { await viewModel.onCancel() }
                } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("clinicalNotesModelStatusRow.actionButton")
            }
        case .ready:
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 8) {
                    Spacer()
                    Button {
                        showRedownloadConfirm = true
                    } label: {
                        Label("Re-download", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isPipelineActive)
                    .accessibilityIdentifier("clinicalNotesModelStatusRow.redownloadButton")

                    Button(role: .destructive) {
                        showRemoveConfirm = true
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    // Gate Remove + Re-download while a clinical-notes pipeline
                    // is in flight (#121). The drain inside
                    // `AppState.removeClinicalNotesModel()` would still close
                    // the race correctly if the user forced a remove, but the
                    // resulting cancellation flips the Review screen to a
                    // fallback banner that the practitioner didn't ask for —
                    // gating the button keeps the UX honest. The accessibility
                    // identifier stays stable across enabled / disabled so
                    // existing UI tests don't need conditional locators.
                    .disabled(viewModel.isPipelineActive)
                    .accessibilityIdentifier("clinicalNotesModelStatusRow.actionButton")
                }
                if viewModel.isPipelineActive {
                    Text("Cannot remove while generating notes — finish the active note first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("clinicalNotesModelStatusRow.pipelineActiveCaption")
                }
            }
        case .failed:
            HStack {
                Spacer()
                Button {
                    showDownloadConfirm = true
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.warmAmber)
                .accessibilityIdentifier("clinicalNotesModelStatusRow.actionButton")
            }
        }
    }

    // MARK: - Helpers

    private var isReady: Bool {
        if case .ready = viewModel.state { return true }
        return false
    }

    /// Manifest-size in human-readable form. `0` is rare (manifest absent)
    /// but harmless — `ByteCountFormatter` returns "Zero KB".
    private var formattedSize: String {
        Self.byteFormatter.string(fromByteCount: viewModel.manifestSizeBytes)
    }
}

// MARK: - Previews

#Preview("Idle") {
    ClinicalNotesModelStatusRow(
        viewModel: ClinicalNotesModelStatusViewModel(
            state: .idle,
            manifestSizeBytes: 5_250_000_000
        )
    )
    .frame(width: 600)
    .padding()
}

#Preview("Downloading") {
    ClinicalNotesModelStatusRow(
        viewModel: ClinicalNotesModelStatusViewModel(
            state: .downloading,
            progress: 0.42,
            manifestSizeBytes: 5_250_000_000
        )
    )
    .frame(width: 600)
    .padding()
}

#Preview("Ready") {
    ClinicalNotesModelStatusRow(
        viewModel: ClinicalNotesModelStatusViewModel(
            state: .ready,
            progress: 1,
            manifestSizeBytes: 5_250_000_000,
            modelDirectoryURL: URL(fileURLWithPath: "/Users/example/Library/Application Support/com.speechtotext.app/Models/gemma-4-e4b-it-4bit")
        )
    )
    .frame(width: 600)
    .padding()
}

#Preview("Failed") {
    ClinicalNotesModelStatusRow(
        viewModel: ClinicalNotesModelStatusViewModel(
            state: .failed,
            manifestSizeBytes: 5_250_000_000
        )
    )
    .frame(width: 600)
    .padding()
}
