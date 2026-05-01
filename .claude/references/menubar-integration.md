# Menu-Bar Integration

> **Load this when:** touching the menu-bar surface, the recording
> modal window, global hotkey registration (Carbon), or the
> Accessibility-API-based text insertion path. Relevant for issues #11,
> #12, #13 and anything that opens a new window.

Reference for the hybrid SwiftUI + AppKit architecture the existing app
already uses. The Clinical Notes Mode additions ride on top of this
shape; they do not introduce a new window-management pattern.

---

## App shell

```swift
@main
struct SpeechToTextApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("Speech-to-Text", systemImage: "mic.fill") {
            MenuBarView()
                .environment(appState)
        }
        .menuBarExtraStyle(.window)
    }
}
```

- `MenuBarExtra(style: .window)` gives us a popover-like SwiftUI panel
  from the menu-bar icon.
- `AppDelegate` is where non-SwiftUI lifecycle lives: singleton guard,
  hotkey registration, modal window presentation.

---

## Singleton guard

`AppDelegate.applicationDidFinishLaunching` terminates duplicate
instances:

```swift
if NSRunningApplication.runningApplications(
    withBundleIdentifier: Bundle.main.bundleIdentifier!
).count > 1 {
    NSApp.terminate(nil)
    return
}
```

Important for a menu-bar app — a second launched copy would double-
register the hotkey and double-present the modal.

---

## Global hotkey (Carbon)

`KeyboardShortcuts` (sindresorhus SPM) wraps Carbon under the hood.
Registration happens once, in `AppDelegate`.

```swift
extension KeyboardShortcuts.Name {
    static let startRecording = Self("startRecording", default: .init(.space, modifiers: [.command, .option]))
}

KeyboardShortcuts.onKeyDown(for: .startRecording) { [weak self] in
    Task { @MainActor in await self?.showRecordingModal() }
}
```

- Hotkey latency target: < 50 ms from keydown to modal visible.
- Carbon handlers run on the main thread — safe to call `@MainActor`
  methods without a hop.
- `KeyboardShortcuts` stores the user's rebinding in `UserDefaults`
  automatically; the settings UI uses `KeyboardShortcuts.Recorder`.

For Clinical Notes Mode the `#11` toggle is paired with a **second**
dedicated hotkey, `clinicalNotesRecord` (#91), and a sibling
**Home-tab trigger row** "Start Clinical Note" (#97 — supersedes the
short-lived menu-bar item shipped in #92). The default
`holdToRecord` / `toggleRecording` chord stays untouched: pure STT,
glass overlay, text insertion. Both clinical surfaces post the same
`.showRecordingModal` notification with `userInfo["clinicalMode"] =
true`, which AppDelegate's existing observer handles by presenting
`LiquidGlassRecordingModal` constructed with `clinicalMode: true`
(auto-starts recording on present via the modal's `.task(id:)`).

The clinical chord is **unbound by default** to avoid OS / browser /
IDE conflicts on install; the Home-tab row provides a tap-target
for discoverability and for hands-off-keyboard moments. Both are
gated by the toggle and Cliniko credential presence: when either
gate flips off, `KeyboardShortcuts.disable(.clinicalNotesRecord)`
runs (chord side) and the Home-tab row hides itself
(`HomeSection.refreshClinicalNotesGate()`), so neither surface fires
when prerequisites are missing. The Settings → Clinical Notes
"Recording shortcut" row uses `ShortcutRecorderView`'s `validate:`
closure to reject any chord already bound to `.holdToRecord` or
`.toggleRecording`.

`HomeSection.refreshClinicalNotesGate()` runs in the section's
`.task` and `.onAppear`, so toggle / credential changes made
elsewhere in the session are picked up the next time the user
lands on Home.

The macOS menu-bar dropdown itself is **kept ultra-minimal** — only
"Open Speech to Text" (`,`) and "Quit" (`⌘Q`). The clinical-notes
trigger lived there briefly under #92 but moved to MainView under
#97 because doctors live in MainView (configuring or reviewing)
rather than fishing for the system-tray icon.

---

## Recording modal window

```swift
@MainActor
private func showRecordingModal() {
    guard recordingWindow == nil else { return }

    let contentView = RecordingModal(viewModel: RecordingViewModel()) { [weak self] in
        self?.recordingWindow?.close()
        self?.recordingWindow = nil
    }

    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
        styleMask: [.borderless, .fullSizeContentView],
        backing: .buffered,
        defer: false
    )
    window.contentView = NSHostingView(rootView: contentView)
    window.backgroundColor = .clear
    window.isOpaque = false
    window.level = .floating
    window.center()
    window.makeKeyAndOrderFront(nil)

    recordingWindow = window
}
```

Key points:
- `level: .floating` keeps the modal above other apps.
- `backgroundColor = .clear` + `isOpaque = false` + an
  `.ultraThinMaterial` background on the SwiftUI root is how the
  "frosted glass" look works.
- The `onDismiss` closure on `RecordingModal` is responsible for
  nil'ing the stored window — otherwise the second hotkey press does
  nothing (guard hits).
- The **`ReviewScreen`** (#13) uses the same shape: new floating window
  presented from AppDelegate, SwiftUI root in `NSHostingView`, dismiss
  through a closure that clears the stored reference.

---

## Text insertion via Accessibility

`TextInsertionService` has two paths:

1. **Primary**: `NSPasteboard.general` + simulated `⌘V`. Fast, reliable.
2. **Fallback**: `AXUIElement` APIs to set the focused element's value
   directly. Used when `⌘V` fails (e.g. some Electron apps).

Permission requirements:
- Microphone → TCC entry handled at first recording.
- Accessibility → `AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true])`.
  If `AXIsProcessTrusted()` is false, the service surfaces an error
  rather than silently no-op'ing.

For Clinical Notes Mode export, the flow goes Cliniko-direct — the
accessibility path is **not** used to paste the SOAP note into a
browser window. That would be a slow-and-fragile alternative; the
Cliniko API export (#14) is the only supported path.

---

## Bundle-ID permission reset

If the signed bundle ID changes between builds (dev → release, team
ID swap, local unsigned builds), macOS invalidates previously-granted
TCC entries. The app detects this at launch:

1. Compare current `Bundle.main.bundleIdentifier` to the last-known
   value stored in UserDefaults.
2. If different, reset the "permissions already granted"
   UserDefaults flag so the onboarding flow re-prompts.

This matters for Clinical Notes Mode: if the doctor re-signs with a
different team ID, they'll be re-prompted for mic + accessibility, and
their Keychain-stored Cliniko key is accessible (Keychain entries are
scoped by bundle-id prefix, so they survive a simple re-sign with the
same team).

---

## Related files

- `Sources/SpeechToTextApp/AppDelegate.swift` — singleton guard, hotkey,
  modal presentation.
- `Sources/SpeechToTextApp/AppState.swift` — `@Observable @MainActor`
  root state injected into SwiftUI.
- `Sources/Services/TextInsertionService.swift` — paste / AX fallback.
- `Sources/Services/PermissionService.swift` — TCC checks + prompts.
