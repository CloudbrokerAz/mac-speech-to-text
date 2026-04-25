// ManipulationsChecklist.swift
// macOS Local Speech-to-Text Application
//
// Right-pane manipulations checklist for `ReviewScreen` (#13). Renders
// the static `ManipulationsRepository` taxonomy as a stable-ordered
// list of toggles bound to `ReviewViewModel`.
//
// PHI: this view sees no PHI — manipulations are static taxonomy. The
// selection state on `StructuredNotes.selectedManipulationIDs` is also
// non-PHI metadata. The view stays purely presentational; logging is
// owned by the VM.

import SwiftUI

/// Manipulations checklist. Stable-ordered per
/// `ManipulationsRepository.all` — that ordering is a UI contract per
/// the repository docs.
struct ManipulationsChecklist: View {
    @Bindable var viewModel: ReviewViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Manipulations")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(Color.iconPrimaryAdaptive)
                .accessibilityAddTraits(.isHeader)

            if viewModel.manipulationsList.isEmpty {
                emptyTaxonomyBanner
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(viewModel.manipulationsList) { manipulation in
                            manipulationRow(manipulation)
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("reviewScreen.manipulations")
    }

    /// Surface a structural-only banner when the taxonomy failed to
    /// load from the bundle — the bundle resource is a `Package.swift`
    /// build invariant (#6), so an empty taxonomy means a build went
    /// wrong rather than something the practitioner can fix. Don't
    /// silently render a blank checklist.
    private var emptyTaxonomyBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.amberBright)
            Text("Manipulations taxonomy not loaded — contact support before exporting.")
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .accessibilityIdentifier("reviewScreen.manipulations.emptyTaxonomyBanner")
    }

    private func manipulationRow(_ manipulation: Manipulation) -> some View {
        let selected = viewModel.isManipulationSelected(id: manipulation.id)
        return Button {
            viewModel.toggleManipulation(id: manipulation.id)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundStyle(selected ? Color.amberPrimary : Color.iconSecondaryAdaptive)
                    .frame(width: 18)

                Text(manipulation.displayName)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground(selected: selected))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("reviewScreen.manipulations.row.\(manipulation.id)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func rowBackground(selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(selected ? Color.amberLight.opacity(0.35) : Color.clear)
    }
}
