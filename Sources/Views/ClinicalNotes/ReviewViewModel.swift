// ReviewViewModel.swift
// macOS Local Speech-to-Text Application
//
// View model behind the ReviewScreen (#13). Owns:
//   - SessionStore-backed bindings for the four SOAP fields,
//   - manipulation-checklist selection state,
//   - excluded-content re-add routing (default Subjective; last-focused
//     SOAP field if focused within the last `reAddTargetWindow` seconds),
//   - the raw-transcript sheet and excluded drawer toggle states,
//   - cancel + export gestures (the latter posts a notification handed
//     off to #14's export flow).
//
// PHI: every SOAP field, manipulation selection, and excluded snippet
// reaches through this view model. Logging is structural-only —
// counts and structural state, never bodies. See
// `.claude/references/phi-handling.md`.

import Foundation
import Observation
import OSLog
import SwiftUI

/// One of the four SOAP fields. Single source of truth for: keyboard-focus
/// routing (⌘1–⌘4), re-add destination resolution, presentation labels,
/// accessibility identifiers, and the read/write `WritableKeyPath` into
/// `StructuredNotes`. Adding a fifth section means: add the case, add a
/// branch to `notesKeyPath`, and the compiler will surface every other
/// site that needs updating.
///
/// `Int` raw value reserved for ordered iteration via `allCases` — not a
/// stable serialisation contract (PHI types in this project are
/// session-only and never persisted).
enum SOAPField: Int, CaseIterable, Sendable, Hashable {
    case subjective
    case objective
    case assessment
    case plan

    /// User-facing section label.
    var displayName: String {
        switch self {
        case .subjective: return "Subjective"
        case .objective: return "Objective"
        case .assessment: return "Assessment"
        case .plan: return "Plan"
        }
    }

    /// Stable accessibility identifier suffix. Also used as a structural
    /// log key (`OSLog` `privacy: .public`) — both the test framework
    /// and the log alphabet are stable contracts on this string.
    var accessibilityID: String {
        switch self {
        case .subjective: return "subjective"
        case .objective: return "objective"
        case .assessment: return "assessment"
        case .plan: return "plan"
        }
    }

    /// Writable projection into `StructuredNotes` for the matching SOAP
    /// string. Lets `value(for:)` and `setValue(_:for:)` collapse to a
    /// single line each, and centralises the SOAPField↔StructuredNotes
    /// mapping in one switch — adding a section can only happen by
    /// adding both an enum case and a key path on the same line.
    var notesKeyPath: WritableKeyPath<StructuredNotes, String> {
        switch self {
        case .subjective: return \.subjective
        case .objective: return \.objective
        case .assessment: return \.assessment
        case .plan: return \.plan
        }
    }
}

/// `@Observable @MainActor` view model for `ReviewScreen` (#13).
///
/// Service references are `@ObservationIgnored` — `SessionStore` is a
/// `@MainActor`-isolated `@Observable` class today, but storing any
/// non-value reference on another `@Observable` triggers the actor-
/// existential scan documented in `.claude/references/concurrency.md` §1
/// (the same crash pattern that bit `RecordingViewModel`). The annotation
/// is correct prophylactic hygiene.
///
/// Lifetime: this VM is constructed by `ReviewWindowController` once per
/// window presentation and torn down when the window closes. It does not
/// outlive a clinical session.
@Observable
@MainActor
final class ReviewViewModel {

    // MARK: - Observed state

    /// Last SOAP field the practitioner focused **and when**, used for
    /// re-add routing. The pair is a single optional so the two halves
    /// cannot drift apart — illegal-state-by-design.
    private(set) var lastFocus: FocusSnapshot?

    /// Whether the excluded-content drawer is expanded. Defaults to
    /// expanded so the practitioner sees the available re-add affordances
    /// without an extra interaction on first render.
    /// Public-mutable so SwiftUI two-way bindings (`@Bindable`) work; do
    /// not mutate from non-view code.
    var isExcludedDrawerOpen: Bool = true

    /// Whether the read-only raw-transcript sheet is visible.
    /// Public-mutable so SwiftUI two-way bindings (`@Bindable`) work; do
    /// not mutate from non-view code.
    var isRawTranscriptSheetOpen: Bool = false

    /// The export-flow VM presented by `triggerExport()` — driving
    /// `.sheet(item:)` on `ReviewScreen`. `nil` while the sheet is
    /// dismissed; populated by `triggerExport()` via the injected
    /// factory; cleared by `dismissExportFlow()` (called from the
    /// host's sheet `onDismiss`).
    ///
    /// Public-mutable so SwiftUI two-way bindings (`@Bindable`) work; do
    /// not mutate from non-view code.
    var exportFlowSheet: ExportFlowViewModel?

    /// The patient-picker VM presented by `presentPatientPicker()`.
    /// Hosted on the ReviewScreen header so the practitioner can
    /// pick a Cliniko patient before tapping Export.
    ///
    /// Public-mutable so SwiftUI two-way bindings (`@Bindable`) work; do
    /// not mutate from non-view code.
    var patientPickerSheet: PatientPickerViewModel?

    /// Last surfaced error banner, if any. Cleared on retry / dismiss.
    /// Public-mutable so SwiftUI two-way bindings (`@Bindable`) work; do
    /// not mutate from non-view code.
    var errorMessage: String?

    // MARK: - Dependencies

    @ObservationIgnored let sessionStore: SessionStore
    @ObservationIgnored private let manipulationsRepo: ManipulationsRepository

    /// Factory that produces a fresh `ExportFlowViewModel` every
    /// time the practitioner taps Export. Returning `nil` means the
    /// `ExportFlowCoordinator` was never configured — gated on
    /// `coordinatorIsConfigured` so the visible UI never reaches
    /// that branch. Tests pass a fake closure.
    @ObservationIgnored private let makeExportFlowViewModel: () -> ExportFlowViewModel?

    /// Factory that produces a fresh `PatientPickerViewModel` for
    /// the header-hosted picker sheet. Returning `nil` means
    /// `AppState` hasn't wired the Cliniko patient/appointment
    /// services yet (no API key configured) — the UI surfaces a
    /// "set up Cliniko in Settings" message in that case.
    @ObservationIgnored private let makePatientPickerViewModel: () -> PatientPickerViewModel?

    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let reAddTargetWindow: TimeInterval
    @ObservationIgnored private let logger = Logger(
        subsystem: "com.speechtotext",
        category: "ReviewViewModel"
    )

    /// Tuple of the most recent focused field + its timestamp. See
    /// `lastFocus` above.
    struct FocusSnapshot: Sendable, Equatable {
        let field: SOAPField
        let at: Date
    }

    // MARK: - Init

    /// - Parameters:
    ///   - sessionStore: source of truth for `draftNotes` + selection state.
    ///   - manipulations: static taxonomy rendered as the right-pane checklist.
    ///   - reAddTargetWindow: how recently a SOAP field must have been
    ///     focused for a re-added excluded entry to land there instead of
    ///     the default `.subjective`. Default 5 s per the issue spec.
    ///   - now: clock for the focus window. Tests pass a fixed clock.
    init(
        sessionStore: SessionStore,
        manipulations: ManipulationsRepository,
        reAddTargetWindow: TimeInterval = 5.0,
        now: @escaping @Sendable () -> Date = { Date() },
        makeExportFlowViewModel: @escaping () -> ExportFlowViewModel? = { nil },
        makePatientPickerViewModel: @escaping () -> PatientPickerViewModel? = { nil }
    ) {
        self.sessionStore = sessionStore
        self.manipulationsRepo = manipulations
        self.reAddTargetWindow = reAddTargetWindow
        self.now = now
        self.makeExportFlowViewModel = makeExportFlowViewModel
        self.makePatientPickerViewModel = makePatientPickerViewModel
    }

    // MARK: - Manipulations accessor

    /// Stable-ordered taxonomy rendered by the right-pane checklist.
    /// Hides the underlying `ManipulationsRepository` from view code so
    /// the VM is the only thing that knows about the repository.
    var manipulationsList: [Manipulation] {
        manipulationsRepo.all
    }

    // MARK: - Read accessors

    /// The unmodified transcript captured by FluidAudio. Rendered
    /// read-only by `RawTranscriptSheet` and used as the empty-draft
    /// fallback prompt copy.
    var transcript: String {
        sessionStore.active?.recordingSession.transcribedText ?? ""
    }

    /// Whether the active session has a non-empty transcript. Used to
    /// gate "View raw transcript".
    var hasTranscript: Bool {
        !transcript.isEmpty
    }

    /// Excluded snippets that the practitioner has not yet re-added.
    /// Re-added entries hide from the drawer per the wireframe. Order
    /// preserved from the LLM output.
    ///
    /// Duplicate handling is count-based: if the LLM emits the same
    /// snippet twice and the practitioner re-adds it once, one
    /// remaining copy stays in the drawer. This relies on
    /// `SessionStore.excludedReAdded` faithfully appending each re-add;
    /// the dedup guard inside `markExcludedReAdded` collapses repeated
    /// re-adds of the same string into a single audit entry, so the
    /// "re-add one of two duplicates" scenario above effectively
    /// re-adds the first match and leaves any remaining copies in the
    /// drawer until the audit guard is relaxed in a follow-up.
    var excludedEntries: [String] {
        guard let active = sessionStore.active,
              let notes = active.draftNotes else { return [] }
        var remainingReAdds = active.excludedReAdded.reduce(into: [String: Int]()) { acc, snippet in
            acc[snippet, default: 0] += 1
        }
        var result: [String] = []
        for entry in notes.excluded {
            if let count = remainingReAdds[entry], count > 0 {
                remainingReAdds[entry] = count - 1
            } else {
                result.append(entry)
            }
        }
        return result
    }

    /// Number of excluded entries still available to re-add. Drives the
    /// "Excluded (n)" drawer header.
    var excludedRemainingCount: Int { excludedEntries.count }

    /// Whether the export action is enabled. The patient picker (#9) is
    /// hosted from the export-flow sheet (#14); ⌘E is gated until a
    /// patient is selected upstream.
    var canExport: Bool {
        sessionStore.active?.selectedPatientID != nil
    }

    /// Whether `draftNotes` is `nil` — the LLM either hasn't filled it
    /// in yet or fell back via `ClinicalNotesProcessor.Outcome
    /// .rawTranscriptFallback`. The screen renders a "draft from raw
    /// transcript" affordance in that state.
    var hasDraft: Bool {
        sessionStore.active?.draftNotes != nil
    }

    // MARK: - SOAP field accessors

    /// Current value for `field`. Empty string when no draft exists yet
    /// (or no active session, which is unreachable from a presented
    /// `ReviewWindow` but defended against here for the idle-timeout
    /// edge case — see `setValue(_:for:)`).
    func value(for field: SOAPField) -> String {
        guard let notes = sessionStore.active?.draftNotes else { return "" }
        return notes[keyPath: field.notesKeyPath]
    }

    /// Write a new value into `field`. Lazily seeds an empty
    /// `StructuredNotes` if the LLM hasn't populated one yet — keeps
    /// the UI editable in the raw-transcript-fallback path.
    ///
    /// Surfaces a session-loss banner when no active session exists.
    /// In the normal flow this is unreachable (the window only opens
    /// after `AppState.handleClinicalNotesGenerateRequested` has called
    /// `sessionStore.start(from:)`), but the
    /// `SessionStore.checkIdleTimeout()` path can drop `active` while a
    /// review is on screen — in which case every keystroke would
    /// otherwise vanish silently. The banner is the visible signal that
    /// the doctor's recent edits aren't landing.
    func setValue(_ value: String, for field: SOAPField) {
        guard let active = sessionStore.active else {
            // PHI-safe: only the field id and an "expired" sentinel.
            logger.error(
                "ReviewViewModel.setValue dropped — no active session field=\(field.accessibilityID, privacy: .public)"
            )
            errorMessage = "Session expired — please cancel and re-record."
            return
        }
        var notes = active.draftNotes ?? StructuredNotes()
        notes[keyPath: field.notesKeyPath] = value
        sessionStore.setDraftNotes(notes)
    }

    /// Two-way `Binding<String>` for SwiftUI text editors. Writes hop
    /// through `setValue(_:for:)` so every keystroke is reflected in
    /// `SessionStore.draftNotes` (AC item: "All text edits are reflected
    /// in `SessionStore.draftNotes` in real time").
    ///
    /// Strong `[self]` capture is intentional: the VM's lifetime is
    /// bounded by `ReviewWindow.viewModel` (which is `let`), so when the
    /// window tears down the bindings die with it. Using `[weak self]`
    /// would force every binding read to handle `nil` defensively for
    /// no real benefit.
    func binding(for field: SOAPField) -> Binding<String> {
        Binding<String>(
            get: { [self] in self.value(for: field) },
            set: { [self] newValue in self.setValue(newValue, for: field) }
        )
    }

    // MARK: - Manipulation checklist

    /// Whether the given manipulation id is currently selected on the draft.
    func isManipulationSelected(id: String) -> Bool {
        sessionStore.active?.draftNotes?.selectedManipulationIDs.contains(id) ?? false
    }

    /// Toggle a manipulation's selection. Surfaces a session-expired
    /// banner without an active session (see `setValue` for the
    /// idle-timeout rationale). Lazily seeds an empty `StructuredNotes`
    /// if necessary so the checklist works in the
    /// raw-transcript-fallback path.
    func toggleManipulation(id: String) {
        guard let active = sessionStore.active else {
            logger.error(
                "ReviewViewModel.toggleManipulation dropped — no active session"
            )
            errorMessage = "Session expired — please cancel and re-record."
            return
        }
        var notes = active.draftNotes ?? StructuredNotes()
        if let existingIndex = notes.selectedManipulationIDs.firstIndex(of: id) {
            notes.selectedManipulationIDs.remove(at: existingIndex)
        } else {
            notes.selectedManipulationIDs.append(id)
        }
        sessionStore.setDraftNotes(notes)
    }

    // MARK: - Focus tracking

    /// Called by SOAPSectionEditor when its TextEditor takes focus. The
    /// timestamp is what `reAddTargetField` consults to decide whether
    /// the practitioner's "current" field should win over the default.
    func noteFieldFocused(_ field: SOAPField) {
        lastFocus = FocusSnapshot(field: field, at: now())
        sessionStore.touch()
    }

    /// Resolves the destination for a re-added excluded entry.
    ///
    /// - Returns: the SOAP field focused within `reAddTargetWindow`
    ///   seconds of `now()`, or `.subjective` as the documented default.
    func reAddTargetField() -> SOAPField {
        guard let snapshot = lastFocus,
              now().timeIntervalSince(snapshot.at) <= reAddTargetWindow else {
            return .subjective
        }
        return snapshot.field
    }

    // MARK: - Re-add an excluded entry

    /// Move `entry` from the excluded drawer into a SOAP field. The entry
    /// is appended (with a blank-line separator if the destination is
    /// already non-empty) and recorded in `SessionStore.excludedReAdded`
    /// so the drawer hides it on the next render.
    ///
    /// Trailing whitespace on the existing field is normalised before
    /// the separator is added so re-adding twice doesn't pile up
    /// triple-newlines (matters for fields the practitioner has
    /// already edited).
    ///
    /// PHI: structural log only — count of entries before and after, no
    /// content.
    func reAddExcludedEntry(_ entry: String) {
        guard sessionStore.active != nil else {
            logger.error(
                "ReviewViewModel.reAddExcludedEntry dropped — no active session"
            )
            errorMessage = "Session expired — please cancel and re-record."
            return
        }
        let target = reAddTargetField()
        let trimmedExisting = trimmedTrailingWhitespace(value(for: target))
        let combined: String
        if trimmedExisting.isEmpty {
            combined = entry
        } else {
            combined = "\(trimmedExisting)\n\n\(entry)"
        }
        setValue(combined, for: target)
        sessionStore.markExcludedReAdded(entry)
        logger.info(
            // PHI-safe: only the target field name + remaining-excluded count.
            "ReviewViewModel: re-added excluded entry target=\(target.accessibilityID, privacy: .public) remaining=\(self.excludedRemainingCount, privacy: .public)"
        )
    }

    /// Strip trailing whitespace and newlines without touching leading
    /// or interior whitespace (which the practitioner may have edited
    /// intentionally). Stays purely structural — no PHI escapes this
    /// function.
    private nonisolated func trimmedTrailingWhitespace(_ text: String) -> String {
        var end = text.endIndex
        while end > text.startIndex {
            let prior = text.index(before: end)
            if text[prior].isWhitespace || text[prior].isNewline {
                end = prior
            } else {
                break
            }
        }
        return String(text[text.startIndex..<end])
    }

    // MARK: - Drawer / sheet toggles

    func toggleExcludedDrawer() {
        isExcludedDrawerOpen.toggle()
    }

    func presentRawTranscript() {
        guard hasTranscript else { return }
        isRawTranscriptSheetOpen = true
    }

    func dismissRawTranscript() {
        isRawTranscriptSheetOpen = false
    }

    // MARK: - Lifecycle gestures

    /// Cancel review. Drops the active session — PHI cleared from the
    /// store — and posts the dismiss notification so
    /// `ReviewWindowController` closes the window. The notification
    /// carries `self` as the `object` so observers can filter against
    /// concurrent test fixtures or future multiple-VM scenarios.
    func cancelReview() {
        logger.info("ReviewViewModel: cancelReview")
        sessionStore.clear()
        NotificationCenter.default.post(name: .reviewScreenDidDismiss, object: self)
    }

    /// Trigger the export flow (#14). Builds a fresh
    /// `ExportFlowViewModel` via the injected factory and assigns
    /// it to `exportFlowSheet`, which `ReviewScreen` binds to a
    /// `.sheet(item:)` host. The export VM reads patient +
    /// appointment + `draftNotes` from `SessionStore` directly — no
    /// PHI rides the SwiftUI binding.
    ///
    /// Surfaces a structural error banner when the export flow
    /// cannot be presented: no patient selected (gated by
    /// `canExport`), or the coordinator hasn't been configured
    /// (e.g. Cliniko credentials missing — the export factory
    /// returns nil in that case).
    func triggerExport() {
        guard canExport else {
            logger.info("ReviewViewModel: triggerExport blocked — no patient selected")
            errorMessage = "Select a patient before exporting."
            return
        }
        guard let viewModel = makeExportFlowViewModel() else {
            logger.error("ReviewViewModel: triggerExport blocked — coordinator not configured")
            errorMessage = "Cliniko isn't set up — configure your API key in Settings."
            return
        }
        logger.info("ReviewViewModel: triggerExport — sheet presented")
        errorMessage = nil
        exportFlowSheet = viewModel
    }

    /// Dismiss the export-flow sheet. Bound to the host
    /// `.sheet(item:)`'s `onDismiss` so the sheet's close
    /// affordances and the host close converge on a single nil.
    func dismissExportFlow() {
        guard exportFlowSheet != nil else { return }
        logger.info("ReviewViewModel: export sheet dismissed")
        exportFlowSheet = nil
    }

    /// Present the patient-picker sheet. Hosted on the
    /// ReviewScreen header so the practitioner picks a patient
    /// before tapping Export. Surfaces a structural banner when
    /// Cliniko isn't configured.
    func presentPatientPicker() {
        guard let viewModel = makePatientPickerViewModel() else {
            logger.error("ReviewViewModel: presentPatientPicker blocked — coordinator not configured")
            errorMessage = "Cliniko isn't set up — configure your API key in Settings."
            return
        }
        logger.info("ReviewViewModel: patient picker presented")
        errorMessage = nil
        patientPickerSheet = viewModel
    }

    /// Dismiss the patient-picker sheet.
    func dismissPatientPicker() {
        guard patientPickerSheet != nil else { return }
        logger.info("ReviewViewModel: patient picker dismissed")
        patientPickerSheet = nil
    }
}

// MARK: - Notification names

extension Notification.Name {
    /// Posted by `ReviewViewModel.cancelReview()` and on window-close so
    /// `ReviewWindowController` can drop its strong reference. Mirrors
    /// the `mainWindowDidClose` pattern in `MainWindow.swift`.
    static let reviewScreenDidDismiss = Notification.Name("reviewScreenDidDismiss")
}
