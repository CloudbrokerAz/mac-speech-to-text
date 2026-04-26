// ExportFlowView.swift
// macOS Local Speech-to-Text Application
//
// Sheet-hosted SwiftUI surface for the Cliniko export flow (#14).
// Pure presentation — every gesture routes through
// `ExportFlowViewModel`; the view is a pattern-match on
// `viewModel.state` and never holds its own logic.
//
// Design language: Warm Minimalism. Frosted card, amber accents
// from `Color+Theme.swift`, spring `(0.5, 0.7)` animations,
// minimal chrome. Mirrors the ReviewScreen + PatientPickerView
// material shape so the sheet looks of-a-piece.
//
// PHI: the SOAP body never appears in this view. Section char
// counts and dropped-manipulation IDs are the only patient-derived
// values rendered, and both are bounded structural counts /
// opaque taxonomy keys. See `.claude/references/phi-handling.md`.

import SwiftUI

struct ExportFlowView: View {

    @Bindable var viewModel: ExportFlowViewModel

    /// Host's "dismiss the sheet" hook. Driven from the host's
    /// `.sheet(item:)` binding — closing the sheet is "set the item
    /// to nil" rather than a method call on this view.
    let onDismiss: () -> Void

    var body: some View {
        contentForState
            .frame(minWidth: 480, minHeight: 360)
            .padding(24)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .accessibilityIdentifier("exportFlow.sheet")
            .onAppear {
                if case .idle = viewModel.state {
                    viewModel.enterConfirming()
                }
            }
    }

    // MARK: - State router

    @ViewBuilder
    private var contentForState: some View {
        switch viewModel.state {
        case .idle:
            // Brief — `onAppear` transitions to `.confirming` on
            // the next render. Render a placeholder so the sheet
            // doesn't flash empty.
            preparingView
        case .confirming(let summary):
            confirmingView(summary)
        case .uploading:
            uploadingView
        case .succeeded(let report):
            succeededView(report)
        case .failed(let reason):
            failedView(reason)
        }
    }

    // MARK: - Preparing

    private var preparingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Preparing export…")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("exportFlow.preparing")
    }

    // MARK: - Confirming

    @ViewBuilder
    private func confirmingView(_ summary: ExportSummary) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Confirm Export to Cliniko")

            VStack(alignment: .leading, spacing: 8) {
                labelRow("Patient", summary.patientDisplayName)
                appointmentSelector(summary)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.cardBackgroundAdaptive)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.subtleBorderAdaptive, lineWidth: 1)
            )

            sectionCountList(summary.sectionCounts)

            if !summary.resolvedManipulations.isEmpty {
                manipulationsSummary(summary.resolvedManipulations)
            }

            if !summary.droppedManipulationIDs.isEmpty {
                droppedWarning(summary.droppedManipulationIDs)
            }

            if summary.excludedNotExportedCount > 0 {
                excludedWarning(summary.excludedNotExportedCount)
            }

            Spacer(minLength: 0)

            actionRow {
                Button("Cancel") {
                    viewModel.cancelFromConfirming()
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("exportFlow.confirm.cancel")

                Button("Confirm export") {
                    viewModel.confirm()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.amberPrimary)
                .disabled(!summary.appointment.isResolved)
                .keyboardShortcut(.return)
                .accessibilityIdentifier("exportFlow.confirm.submit")
            }
        }
        .accessibilityIdentifier("exportFlow.confirming")
    }

    @ViewBuilder
    private func appointmentSelector(_ summary: ExportSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Appointment")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.iconPrimaryAdaptive)
            Picker("Appointment", selection: appointmentBinding(summary)) {
                Text("Select…").tag(AppointmentSelectorOption.unset)
                Text("No appointment / general note").tag(AppointmentSelectorOption.general)
                if case .appointment(let id) = summary.appointment {
                    Text("Appointment \(id.rawValue)").tag(AppointmentSelectorOption.specific(id))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .accessibilityIdentifier("exportFlow.confirm.appointment")
        }
    }

    private func appointmentBinding(_ summary: ExportSummary) -> Binding<AppointmentSelectorOption> {
        Binding(
            get: {
                switch summary.appointment {
                case .unset: return .unset
                case .general: return .general
                case .appointment(let id): return .specific(id)
                }
            },
            set: { option in
                let resolved: AppointmentSelection
                switch option {
                case .unset: resolved = .unset
                case .general: resolved = .general
                case .specific(let id): resolved = .appointment(id)
                }
                viewModel.setAppointmentSelection(resolved)
            }
        )
    }

    // Local `Hashable` shim for the SwiftUI Picker. The model enum
    // (`AppointmentSelection`) carries an `OpaqueClinikoID` payload
    // and conforms to `Equatable`, but `Picker` needs `Hashable`
    // tags. This wrapper is the type-system answer.
    private enum AppointmentSelectorOption: Hashable {
        case unset
        case general
        case specific(OpaqueClinikoID)
    }

    private func sectionCountList(_ rows: [ExportSummary.SectionCount]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Note summary")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.iconPrimaryAdaptive)
            ForEach(rows) { row in
                HStack {
                    Text(row.field.displayName)
                        .font(.system(size: 12))
                    Spacer()
                    Text("\(row.charCount) chars")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("exportFlow.confirm.sectionCount.\(row.field.accessibilityID)")
            }
        }
    }

    private func manipulationsSummary(_ names: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Manipulations (\(names.count))")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.iconPrimaryAdaptive)
            Text(names.joined(separator: ", "))
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineLimit(2)
        }
        .accessibilityIdentifier("exportFlow.confirm.manipulationsList")
    }

    private func droppedWarning(_ droppedIDs: [String]) -> some View {
        warningBanner(
            icon: "exclamationmark.triangle.fill",
            title: "\(droppedIDs.count) manipulation\(droppedIDs.count == 1 ? "" : "s") no longer in taxonomy",
            detail: "These selections won't be exported. Re-pick from the checklist if needed."
        )
        .accessibilityIdentifier("exportFlow.confirm.droppedWarning")
    }

    private func excludedWarning(_ count: Int) -> some View {
        warningBanner(
            icon: "tray",
            title: "\(count) excluded snippet\(count == 1 ? "" : "s") will not be exported",
            detail: "Re-add anything you want to keep before exporting."
        )
        .accessibilityIdentifier("exportFlow.confirm.excludedWarning")
    }

    // MARK: - Uploading

    private var uploadingView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Exporting to Cliniko…")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
            Text("Don't close this window — the request is on the wire.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("exportFlow.uploading")
    }

    // MARK: - Succeeded

    private func succeededView(_ report: SuccessReport) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(Color.amberPrimary)
            Text("Exported to Cliniko")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
            if !report.auditPersisted {
                Text("Audit log unavailable — note landed on Cliniko, but the local audit row could not be written.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
                    .accessibilityIdentifier("exportFlow.succeeded.auditWarning")
            }
            if !report.droppedManipulationIDs.isEmpty {
                Text("\(report.droppedManipulationIDs.count) stale manipulation\(report.droppedManipulationIDs.count == 1 ? "" : "s") were dropped from the wire body.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
                    .accessibilityIdentifier("exportFlow.succeeded.droppedNote")
            }
            Spacer(minLength: 0)
            Button("Done") {
                onDismiss()
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.amberPrimary)
            .keyboardShortcut(.return)
            .accessibilityIdentifier("exportFlow.succeeded.done")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("exportFlow.succeeded")
    }

    // MARK: - Failed

    @ViewBuilder
    private func failedView(_ reason: ExportFailure) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.errorRed)
                VStack(alignment: .leading, spacing: 2) {
                    Text(failureTitle(reason))
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                    Text(failureDetail(reason))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            if case .validation(let fields) = reason, !fields.isEmpty {
                validationFieldList(fields)
            }

            if case .rateLimited = reason {
                rateLimitCountdownView
            }

            Spacer(minLength: 0)

            actionRow {
                ForEach(failureActions(reason), id: \.id) { action in
                    actionButton(action)
                }
            }
        }
        .accessibilityIdentifier("exportFlow.failed.\(failureCaseID(reason))")
    }

    @ViewBuilder
    private var rateLimitCountdownView: some View {
        if let remaining = viewModel.rateLimitCountdownRemaining, remaining > 0 {
            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .foregroundStyle(.secondary)
                Text("Retry available in \(Int(remaining))s")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("exportFlow.failed.rateLimitCountdown")
        }
    }

    private func validationFieldList(_ fields: [String: [String]]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Cliniko reported field issues")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.iconPrimaryAdaptive)
            ForEach(fields.keys.sorted(), id: \.self) { key in
                HStack(alignment: .top) {
                    Text("•")
                    VStack(alignment: .leading) {
                        Text(key).font(.system(size: 11, weight: .semibold))
                        ForEach(fields[key] ?? [], id: \.self) { msg in
                            Text(msg)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("exportFlow.failed.validationFields")
    }

    // MARK: - Failure copy

    /// Exhaustive enum switch over `ExportFailure` — 12 cases.
    /// `cyclomatic_complexity` silenced (trailing-line annotation)
    /// because splitting would require a parallel "kind" enum and
    /// lose the direct mapping from failure case to user-facing
    /// copy.
    private func failureTitle(_ reason: ExportFailure) -> String { // swiftlint:disable:this cyclomatic_complexity
        switch reason {
        case .unauthenticated:
            return "Cliniko rejected your API key"
        case .forbidden:
            return "Cliniko API key lacks access"
        case .notFound(let resource):
            return "\(resource.rawValue.capitalized) not found in Cliniko"
        case .validation:
            return "Cliniko rejected the note's contents"
        case .rateLimited:
            return "Cliniko rate-limited the request"
        case .server(let status):
            return "Cliniko server error (HTTP \(status))"
        case .transport:
            return "Network error"
        case .responseUndecodable:
            return "Cliniko response unreadable"
        case .requestEncodeFailed:
            return "Couldn't build the request"
        case .cancelled:
            return "Export cancelled"
        case .decoding:
            return "Couldn't read Cliniko's response"
        case .sessionState:
            return "Session state expired"
        }
    }

    /// Same rationale as `failureTitle` — every `ExportFailure`
    /// case (and every `sessionState` sub-case) gets a tailored
    /// message. Splitting just moves the switch.
    private func failureDetail(_ reason: ExportFailure) -> String { // swiftlint:disable:this cyclomatic_complexity
        switch reason {
        case .unauthenticated:
            return "Open Cliniko Settings to re-paste your API key."
        case .forbidden:
            return "Ask your Cliniko admin for treatment-note write access on this account."
        case .notFound(let resource):
            return "The \(resource.rawValue) was removed or isn't visible to you. Re-pick from the patient picker."
        case .validation:
            return "Adjust the SOAP fields and try again."
        case .rateLimited:
            return "Wait for the countdown to clear, then retry."
        case .server:
            return "Cliniko's side reported a server error. POST is not auto-retried — try again when ready."
        case .transport:
            return "We couldn't reach Cliniko. Try again, or copy the note to your clipboard so you don't lose it."
        case .responseUndecodable:
            return "The note may have landed on Cliniko's side. Verify in Cliniko before re-submitting to avoid duplicate records."
        case .requestEncodeFailed:
            return "An internal error built the request. Copy the note to your clipboard and try again."
        case .cancelled:
            return "Dismissed by user. Re-open the export flow to try again."
        case .decoding:
            return "Cliniko's response was malformed. Try again or copy to clipboard."
        case .sessionState(.noActiveSession):
            return "The session expired. Cancel and re-record."
        case .sessionState(.noPatient):
            return "Pick a patient before exporting."
        case .sessionState(.patientIDMalformed):
            return "Internal error. Cancel and re-record."
        case .sessionState(.appointmentUnresolved):
            return "Choose an appointment (or 'No appointment / general note') before confirming."
        case .sessionState(.noDraftNotes):
            return "Add at least one SOAP field before exporting."
        }
    }

    private func failureCaseID(_ reason: ExportFailure) -> String {
        ExportFlowViewModel.caseName(reason).replacingOccurrences(of: ".", with: "-")
    }

    // MARK: - Failure actions

    private struct FailureAction: Identifiable {
        let id = UUID()
        let title: String
        let kind: Kind
        let identifier: String
        let isPrimary: Bool

        enum Kind {
            case retry
            case copyToClipboard
            case openSettings
            case openCliniko
            case dismiss
        }
    }

    private func failureActions(_ reason: ExportFailure) -> [FailureAction] {
        switch reason {
        case .unauthenticated, .forbidden:
            return [
                FailureAction(title: "Cancel", kind: .dismiss, identifier: "exportFlow.failed.cancel", isPrimary: false),
                FailureAction(title: "Open Cliniko Settings", kind: .openSettings, identifier: "exportFlow.failed.openSettings", isPrimary: true)
            ]
        case .responseUndecodable:
            // Deliberately no Retry — the note may have landed.
            return [
                FailureAction(title: "Copy note to clipboard", kind: .copyToClipboard, identifier: "exportFlow.failed.copyClipboard", isPrimary: false),
                FailureAction(title: "Cancel", kind: .dismiss, identifier: "exportFlow.failed.cancel", isPrimary: false)
            ]
        case .transport:
            return [
                FailureAction(title: "Copy note to clipboard", kind: .copyToClipboard, identifier: "exportFlow.failed.copyClipboard", isPrimary: false),
                FailureAction(title: "Cancel", kind: .dismiss, identifier: "exportFlow.failed.cancel", isPrimary: false),
                FailureAction(title: "Retry", kind: .retry, identifier: "exportFlow.failed.retry", isPrimary: true)
            ]
        case .rateLimited:
            return [
                FailureAction(title: "Cancel", kind: .dismiss, identifier: "exportFlow.failed.cancel", isPrimary: false),
                FailureAction(title: "Retry", kind: .retry, identifier: "exportFlow.failed.retry", isPrimary: true)
            ]
        case .server, .validation, .decoding, .requestEncodeFailed:
            return [
                FailureAction(title: "Cancel", kind: .dismiss, identifier: "exportFlow.failed.cancel", isPrimary: false),
                FailureAction(title: "Retry", kind: .retry, identifier: "exportFlow.failed.retry", isPrimary: true)
            ]
        case .notFound, .sessionState:
            // Both surface dismiss-only — the practitioner has to
            // re-pick a patient (notFound) or re-record
            // (sessionState), and reaching the right surface means
            // closing the sheet.
            return [
                FailureAction(title: "Close", kind: .dismiss, identifier: "exportFlow.failed.dismiss", isPrimary: true)
            ]
        case .cancelled:
            return [
                FailureAction(title: "Close", kind: .dismiss, identifier: "exportFlow.failed.dismiss", isPrimary: true)
            ]
        }
    }

    @ViewBuilder
    private func actionButton(_ action: FailureAction) -> some View {
        let button = Button(action.title) {
            handle(action.kind)
        }
        .accessibilityIdentifier(action.identifier)
        if action.isPrimary {
            button
                .buttonStyle(.borderedProminent)
                .tint(Color.amberPrimary)
                .disabled(isPrimaryDisabled(for: action))
                .keyboardShortcut(.return)
        } else {
            button
                .keyboardShortcut(action.kind == .dismiss ? .cancelAction : nil)
        }
    }

    private func isPrimaryDisabled(for action: FailureAction) -> Bool {
        // Retry is gated by the rate-limit countdown.
        guard action.kind == .retry else { return false }
        guard case .failed(.rateLimited) = viewModel.state else { return false }
        return (viewModel.rateLimitCountdownRemaining ?? 0) > 0
    }

    private func handle(_ kind: FailureAction.Kind) {
        switch kind {
        case .retry:
            viewModel.retry()
        case .copyToClipboard:
            viewModel.copyNoteToClipboard()
        case .openSettings:
            viewModel.openClinikoSettings()
            onDismiss()
        case .openCliniko:
            // No public Cliniko deeplink today — we route to
            // settings as the closest available surface. Reserved
            // for a future enhancement.
            onDismiss()
        case .dismiss:
            onDismiss()
        }
    }

    // MARK: - Reusable chrome

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 16, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary)
            .accessibilityAddTraits(.isHeader)
    }

    private func labelRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.iconPrimaryAdaptive)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
        }
    }

    private func warningBanner(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(Color.amberBright)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 11, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.amberLight.opacity(0.3))
        )
    }

    private func actionRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Spacer()
            content()
        }
    }
}
