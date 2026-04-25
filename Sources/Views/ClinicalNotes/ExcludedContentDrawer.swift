// ExcludedContentDrawer.swift
// macOS Local Speech-to-Text Application
//
// Collapsible drawer showing excluded snippets the LLM dropped from the
// SOAP note. Each entry has a `↺` re-add button that hands the entry
// back to `ReviewViewModel.reAddExcludedEntry(_:)` — the VM resolves
// the destination field (default Subjective; last-focused-within-5s if
// applicable) and updates `SessionStore`.
//
// PHI: every excluded snippet is patient data. View stays purely
// presentational. Logging happens in the VM and is structural-only.

import SwiftUI

struct ExcludedContentDrawer: View {
    @Bindable var viewModel: ReviewViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if viewModel.isExcludedDrawerOpen {
                drawerBody
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(.ultraThinMaterial.opacity(0.4),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .animation(
            .spring(response: 0.5, dampingFraction: 0.7),
            value: viewModel.isExcludedDrawerOpen
        )
        .accessibilityIdentifier("reviewScreen.excludedDrawer")
    }

    // MARK: - Header

    private var header: some View {
        Button {
            viewModel.toggleExcludedDrawer()
        } label: {
            HStack(spacing: 8) {
                Text("Excluded")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .tracking(0.6)
                    .foregroundStyle(Color.iconPrimaryAdaptive)

                Text("(\(viewModel.excludedRemainingCount))")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.secondary)

                Spacer()

                Image(systemName: viewModel.isExcludedDrawerOpen ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("reviewScreen.excludedDrawer.toggle")
    }

    // MARK: - Body

    @ViewBuilder
    private var drawerBody: some View {
        let entries = viewModel.excludedEntries
        if entries.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(entries.enumerated()), id: \.element) { _, entry in
                        excludedRow(entry)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
        }
    }

    private var emptyState: some View {
        Text("Nothing excluded.")
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
            .accessibilityIdentifier("reviewScreen.excludedDrawer.empty")
    }

    private func excludedRow(_ entry: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(quoted(entry))
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                viewModel.reAddExcludedEntry(entry)
            } label: {
                Image(systemName: "arrow.uturn.left.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.amberBright)
            }
            .buttonStyle(.plain)
            .help("Re-add to \(viewModel.reAddTargetField().displayName)")
            .accessibilityLabel("Re-add to \(viewModel.reAddTargetField().displayName)")
            .accessibilityIdentifier("reviewScreen.excludedDrawer.row.readd")
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.clear)
        )
    }

    /// Render the entry inside guillemet quotes for visual separation
    /// from the surrounding chrome. Truncation handled by `lineLimit`.
    private func quoted(_ entry: String) -> String {
        "\u{201C}\(entry)\u{201D}"
    }
}
