// ExportFlowCoordinator.swift
// macOS Local Speech-to-Text Application
//
// Singleton wiring for the Cliniko export flow (#14). Sibling to
// `ReviewWindowController` — `AppState.init` configures it once
// with the long-lived dependencies (`SessionStore`,
// `TreatmentNoteExporter`, `ManipulationsRepository`,
// `openClinikoSettings` callback), and `ReviewScreen` calls
// `makeViewModel()` whenever the practitioner taps Export to
// build a fresh `ExportFlowViewModel` for that flow.
//
// Why a coordinator instead of injecting deps via `ReviewViewModel`?
// The export flow's collaborators (`TreatmentNoteExporter`,
// `ClinikoClient`, the settings-routing callback) are orthogonal to
// the review flow's concerns. Threading them through `ReviewViewModel`
// would couple the review surface to Cliniko state it doesn't need.
// The coordinator keeps the seam narrow — `ReviewViewModel` only
// asks "build me a fresh export VM" and the coordinator owns the
// rest.

import AppKit
import Foundation

/// Singleton factory for `ExportFlowViewModel`. Configured once by
/// `AppState.init`; `makeViewModel()` is the only method called from
/// the view layer.
@MainActor
final class ExportFlowCoordinator {

    // MARK: - Singleton

    static let shared = ExportFlowCoordinator()

    // MARK: - Configuration

    private var sessionStore: SessionStore?
    private var exporter: TreatmentNoteExporter?
    private var manipulations: ManipulationsRepository?
    private var openClinikoSettings: (() -> Void)?
    private var closeReviewWindow: (() -> Void)?

    private init() {}

    /// Wire the coordinator. Called once by `AppState.init` with
    /// the production collaborators. Subsequent calls overwrite —
    /// tests use this to swap fakes between scenarios.
    ///
    /// - Parameters:
    ///   - sessionStore: source of truth for the active session.
    ///     The export VM reads patient/appointment/notes from here.
    ///   - exporter: actor-isolated Cliniko POST + audit-write
    ///     pipeline (issue #10).
    ///   - manipulations: taxonomy used for the confirmation
    ///     summary's resolved-manipulation list and the
    ///     "dropped" warning.
    ///   - openClinikoSettings: routes the practitioner to the
    ///     Cliniko credentials surface on 401 / 403. AppState
    ///     wires this to `MainWindowController.shared.showSection(.clinicalNotes)`.
    ///   - closeReviewWindow: dismisses the review window after a
    ///     successful export. AppState wires this to
    ///     `ReviewWindowController.shared.close()`.
    func configure(
        sessionStore: SessionStore,
        exporter: TreatmentNoteExporter,
        manipulations: ManipulationsRepository,
        openClinikoSettings: @escaping () -> Void,
        closeReviewWindow: @escaping () -> Void
    ) {
        self.sessionStore = sessionStore
        self.exporter = exporter
        self.manipulations = manipulations
        self.openClinikoSettings = openClinikoSettings
        self.closeReviewWindow = closeReviewWindow
    }

    /// Whether `configure(...)` has been called. The view layer
    /// gates the Export button on this so a misconfigured app
    /// doesn't crash on first tap.
    var isConfigured: Bool {
        sessionStore != nil
            && exporter != nil
            && manipulations != nil
            && openClinikoSettings != nil
            && closeReviewWindow != nil
    }

    // MARK: - Factory

    /// Build a fresh `ExportFlowViewModel` for one export sheet
    /// presentation. Each tap of Export gets a new VM so the FSM
    /// state doesn't leak across sessions; the previous one is
    /// dropped when the sheet dismisses.
    ///
    /// Returns `nil` when the coordinator has not been configured —
    /// callers gate the Export button on `isConfigured` to avoid
    /// reaching this branch from the visible UI.
    func makeViewModel() -> ExportFlowViewModel? {
        guard let sessionStore,
              let exporter,
              let manipulations,
              let openClinikoSettings,
              let closeReviewWindow else {
            return nil
        }
        let dependencies = ExportFlowDependencies(
            exporter: exporter,
            manipulations: manipulations,
            onSuccess: {
                // Order matters. Clear PHI from memory **before**
                // the window dismisses so the windowWillClose hook
                // (`ReviewWindow.swift`) lands on a no-op clear
                // rather than racing with a re-entry from a
                // future export attempt.
                sessionStore.clear()
                closeReviewWindow()
            },
            openClinikoSettings: openClinikoSettings,
            copyToClipboard: { body in
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(body, forType: .string)
            }
        )
        return ExportFlowViewModel(
            sessionStore: sessionStore,
            dependencies: dependencies
        )
    }
}
