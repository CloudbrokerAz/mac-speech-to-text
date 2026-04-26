# AGENTS.md — `Sources/Views/ClinicalNotes/`

> **Load this when:** writing or reviewing anything in
> `Sources/Views/ClinicalNotes/` — the post-recording UI surface.
> For the service seam underneath, see
> [`../../Services/ClinicalNotes/AGENTS.md`](../../Services/ClinicalNotes/AGENTS.md).
> For HTTP / Cliniko services, see
> [`../../Services/Cliniko/AGENTS.md`](../../Services/Cliniko/AGENTS.md).

## Purpose

This subdirectory holds every post-recording clinical-notes view. The
flow is:

1. **Disclaimer** (one-time ack, gated by `UserDefaults`) — see
   issue [#12](https://github.com/CloudbrokerAz/mac-speech-to-text/issues/12).
2. **ReviewScreen** (two-column SOAP editor + manipulations checklist
   + excluded drawer, hosted in a non-floating `NSWindow`) — see
   issue [#13](https://github.com/CloudbrokerAz/mac-speech-to-text/issues/13).
3. **PatientPicker** sheet (Cliniko search → appointment list).
4. **ExportFlow** sheet (confirm → POST → success / failure) — see
   issue [#14](https://github.com/CloudbrokerAz/mac-speech-to-text/issues/14).

All view models are `@Observable @MainActor`. All views adhere to the
Warm Minimalism aesthetic from the root
[`AGENTS.md`](../../../AGENTS.md) (frosted `.ultraThinMaterial`, amber
palette in `Utilities/Extensions/Color+Theme.swift`, spring
`(0.5, 0.7)` animations, minimal chrome).

---

## Key types

### Disclaimer

| Type | Role |
|---|---|
| `SafetyDisclaimerView` | One-time "drafting assistant, not a diagnostic tool" overlay. No close affordance, no ⎋, no tap-outside-to-dismiss — only the "I understand, continue" button. Carries no `@Observable` VM; the host (`LiquidGlassRecordingModal`) owns the `UserDefaults` ack flag. See [#12](https://github.com/CloudbrokerAz/mac-speech-to-text/issues/12). |

### Review

| Type | Role |
|---|---|
| `ReviewScreen` | Two-column wireframe-locked layout (SOAP editors left, manipulations + excluded drawer right). Header with patient chip + draft badge, action bar with View raw transcript / Cancel / Export to Cliniko. Owns the shared `@FocusState<SOAPField?>` and the hidden ⌘1–⌘4 + ⌘E shortcut sink. |
| `ReviewWindow` | `@MainActor` `NSObject` `NSWindowDelegate` wrapping a single `NSWindow`. **Window level is `.normal`** (long-form editor) — `isRestorable = false` so transcript / draft never lands in NSWindow restoration archives. `windowWillClose` calls `SessionStore.clear()` as the title-bar-X PHI chokepoint. |
| `ReviewWindowController` | `@MainActor` singleton. Configured once by `AppState.init` with a `SessionStore`, `ManipulationsRepository`, and the export / patient-picker factories. Constructs the `ReviewViewModel` outside the SwiftUI root (concurrency §1 mitigation) and presents the window. |
| `ReviewViewModel` | `@Observable @MainActor`. Owns SOAP-field bindings, manipulation toggles, focus tracking, excluded re-add routing, sheet presentation state for raw-transcript / export / patient-picker, and the cancel + export gestures. All service references are `@ObservationIgnored`. |
| `SOAPSectionEditor` | One editable section. Receives a `Binding<String>` (via `viewModel.binding(for:)`) and the host's `FocusState<SOAPField?>.Binding` so all four sections share a single focus chain. |
| `ManipulationsChecklist` | Right-column, stable-ordered taxonomy from `ManipulationsRepository`. Surfaces a structural empty-taxonomy banner when the bundle resource fails to load. View itself sees no PHI — manipulations are static taxonomy. |
| `ExcludedContentDrawer` | Right-column collapsible drawer of LLM-excluded snippets, defaults to expanded. Each row has a re-add button. Header shows `Excluded (n)` from `viewModel.excludedRemainingCount`. |
| `RawTranscriptSheet` | Read-only `.sheet` surface for the unmodified transcript. Used as a sanity-check during edit and as the primary surface in the LLM-fallback path. |

### Picker

| Type | Role |
|---|---|
| `PatientPickerView` | Two-pane SwiftUI surface — search field on the left with `SearchPhase`-driven results, appointment list on the right with `AppointmentPhase`-driven loading / loaded / error rows. Sheet chrome (Cancel / Done) lives in `ReviewScreen.PatientPickerSheetHost`. |
| `PatientPickerViewModel` | `@Observable @MainActor` `Identifiable`. Owns the debounced search lifecycle (300ms default; `0` in tests), kicks off the appointment fetch on patient select, and writes selections through `SessionStore.setSelectedPatient(id:displayName:)` / `setSelectedAppointment(id:)`. Service refs are `@ObservationIgnored`. |

### Export

| Type | Role |
|---|---|
| `ExportFlowView` | `.sheet`-hosted FSM router over `viewModel.state` — `.idle` / `.confirming` / `.uploading` / `.succeeded` / `.failed`. Pure presentation; every gesture routes through the VM. Cancel is disabled during `.uploading` (POST is non-idempotent). |
| `ExportFlowViewModel` | `@Observable @MainActor` `Identifiable` FSM. Computes the pre-flight `ExportSummary`, runs the single-shot upload Task, translates `ClinikoError` / `TreatmentNoteExporter.Failure` into a UI-shaped `ExportFailure`, and drives the `.rateLimited` countdown. Constructed via `ExportFlowCoordinator.shared.makeViewModel()` which lives at [`../../Services/ClinicalNotes/ExportFlowCoordinator.swift`](../../Services/ClinicalNotes/ExportFlowCoordinator.swift). |

---

## Re-add drawer behaviour

The `ExcludedContentDrawer`'s "↺ re-add to SOAP section" affordance is
the wireframe-defining mechanic for the right column:

- Each row's re-add button calls `viewModel.reAddExcludedEntry(_:)`.
- Destination is resolved by `ReviewViewModel.reAddTargetField()`:
  the **last-focused SOAP field** if focus landed within the
  `reAddTargetWindow` (default 5s) of `now()`, else `.subjective`.
- The entry is appended to the destination field with a blank-line
  separator if the destination is already non-empty (trailing
  whitespace is normalised first so re-adding twice doesn't pile up
  triple-newlines).
- The re-added snippet is recorded on
  `SessionStore.excludedReAdded`. The drawer's visible list is the
  full `notes.excluded` minus a count-based subtraction of
  `excludedReAdded` — so re-adding one of two duplicate snippets
  leaves the second copy in the drawer (see `excludedEntries` for
  the duplicate-handling rationale).
- The rest of the drawer state (collapse / expand, other rows) is
  untouched. No drawer-wide reset, no scroll jump.

Full source for the destination resolution + write-through:
`ReviewViewModel.reAddTargetField()` and
`ReviewViewModel.reAddExcludedEntry(_:)`.

---

## Common pitfalls

### `@Observable` + actor existential

Every actor existential field on a view model in this directory must
be `@ObservationIgnored` — otherwise SwiftUI's observation scan
crashes with `EXC_BAD_ACCESS`. The SwiftLint custom rule
`observable_actor_existential_warning` catches the pattern. View
models in this directory all follow the rule (`SessionStore`,
`ManipulationsRepository`, `TreatmentNoteExporter`, the picker
services, and every factory closure are all annotated). See
[`../../../.claude/references/concurrency.md`](../../../.claude/references/concurrency.md)
§1 for the "construct VM outside the SwiftUI root" mitigation —
`ReviewWindowController.present()` and the export / picker factories
do this.

### PHI in views

Views in this directory see SOAP body, transcript, patient names,
DOBs, emails, and excluded snippets. **None of that may be `print` /
`OSLog` / `assertionFailure(...)` from a view.** All logging in this
directory lives on the view models, and is structural-only (FSM case
name, char counts, accessibility-id field tags). See
[`../../../.claude/references/phi-handling.md`](../../../.claude/references/phi-handling.md).

### Window level on `ReviewWindow`

`ReviewWindow.makeWindow()` deliberately uses `level = .normal` (vs
the recording modal's `.floating`) because the review surface is a
long-form editor, not a transient capture overlay. Don't change it
to `.floating` — the regression risk is the editor jumping above
unrelated app windows the practitioner is referencing.

`isRestorable = false` is also load-bearing — it prevents transcript
or draft content from being archived in NSWindow state restoration.
Don't flip this without a session-only-PHI review.

### `ExportFlowCoordinator.shared` not configured

`ReviewWindowController.configure(...)` accepts the export and
patient-picker factories with `{ nil }` defaults. When Cliniko isn't
set up (no API key in Keychain), the factory returns `nil`:

- `ReviewViewModel.triggerExport()` shows
  `"Cliniko isn't set up — configure your API key in Settings."` in
  the action-bar error banner.
- `ReviewViewModel.presentPatientPicker()` shows the same banner.
- `canExport` stays `false` until a patient is selected, so ⌘E and
  the Export button stay disabled too.

Don't surface a sheet that the user can't act on — keep the banner
copy aligned with the Settings entry-point name.

### `@ObservedObject` / `@StateObject` / `ObservableObject`

Forbidden in this codebase (root `AGENTS.md` rule). Use `@State` /
`@Bindable` / `@Environment` with `@Observable`. Every view in this
directory takes its VM as `@Bindable var viewModel`.

### Accessibility focus order

`ReviewScreen` ships a multi-pane focus chain: ⌘1–⌘4 route the
shared `@FocusState<SOAPField?>` to the matching SOAP editor, and
⌘E triggers Export. The hidden-button shortcut sink in
`shortcutSink` is the only legitimate place to register those.
Snapshot tests in `ReviewScreenRenderTests` pin the accessibility
identifiers — if you reorder the focus chain or rename a shortcut,
update them.

---

## Testing notes

### ViewInspector crash-detection

Every `@Observable` view model in this directory gets a render-crash
test:

- `Tests/SpeechToTextTests/Views/ReviewScreenRenderTests.swift`
- `Tests/SpeechToTextTests/Views/SafetyDisclaimerViewRenderTests.swift`
- `Tests/SpeechToTextTests/Views/PatientPickerViewRenderTests.swift`
- `Tests/SpeechToTextTests/Views/ExportFlowViewRenderTests.swift`

Standard idiom: instantiate the VM, then the view, then access
`view.body`. See
[`../../../.claude/references/testing-conventions.md`](../../../.claude/references/testing-conventions.md).

### Snapshot tests

Per the locked decisions in the root [`AGENTS.md`](../../../AGENTS.md),
**snapshot tests are scoped to ReviewScreen + SafetyDisclaimer only**
using `pointfreeco/swift-snapshot-testing` v1.17+. Don't add snapshot
coverage for `PatientPickerView`, `ExportFlowView`, or any of the
sub-components — render-crash + assertion tests are the contract for
those.

### No real LLM, no real Cliniko, no real Keychain

Every test in this directory uses injected fakes:

- `MockLLMProvider` for transcript → SOAP.
- `URLProtocolStub` for Cliniko HTTP (see the `makeExporter()`
  helper in `ExportFlowViewRenderTests`).
- `InMemorySecureStore` / `InMemoryAuditStore` for the credential and
  audit seams.

Real LLM goldens are gated by `RUN_MLX_GOLDEN=1` and run nightly
only. Real Cliniko / Keychain is never exercised in CI. See
[`../../../.claude/references/testing-conventions.md`](../../../.claude/references/testing-conventions.md).

### ViewInspector limitation on `keyboardShortcut`

ViewInspector has no introspection API for `.keyboardShortcut(...)`
— pinning a shortcut directly in a test will fail. Pin the button's
**label text** or accessibility identifier instead. This came up in
PR [#66](https://github.com/CloudbrokerAz/mac-speech-to-text/pull/66)
and applies to the disclaimer's `.return` shortcut, the export
sheet's confirm / retry buttons, and the review action bar.

---

## Related

Topic-router references:

- [`../../../.claude/references/concurrency.md`](../../../.claude/references/concurrency.md) — `@Observable` + actor existential rules (§1), Audio callbacks + `@MainActor` (§2).
- [`../../../.claude/references/testing-conventions.md`](../../../.claude/references/testing-conventions.md) — ViewInspector + snapshot scoping.
- [`../../../.claude/references/phi-handling.md`](../../../.claude/references/phi-handling.md) — never-log policy.
- [`../../../.claude/references/menubar-integration.md`](../../../.claude/references/menubar-integration.md) — `NSWindow` / floating-window patterns.

Sister AGENTS.md:

- [`../../Services/ClinicalNotes/AGENTS.md`](../../Services/ClinicalNotes/AGENTS.md) — `SessionStore`, `ClinicalNotesProcessor`, `ExportFlowCoordinator`, `ManipulationsRepository`, `LLMProvider`.
- [`../../Services/Cliniko/AGENTS.md`](../../Services/Cliniko/AGENTS.md) — `ClinikoClient`, `TreatmentNoteExporter`, `AuditStore`, `ClinikoCredentialStore`.

Issues:

- [#1 — Clinical Notes Mode (EPIC)](https://github.com/CloudbrokerAz/mac-speech-to-text/issues/1)
- [#12 — Safety Disclaimer modal](https://github.com/CloudbrokerAz/mac-speech-to-text/issues/12)
- [#13 — ReviewScreen two-column layout](https://github.com/CloudbrokerAz/mac-speech-to-text/issues/13)
- [#14 — Export flow (patient picker → confirm → POST)](https://github.com/CloudbrokerAz/mac-speech-to-text/issues/14)
- [#17 — Component AGENTS.md files (this file)](https://github.com/CloudbrokerAz/mac-speech-to-text/issues/17)
