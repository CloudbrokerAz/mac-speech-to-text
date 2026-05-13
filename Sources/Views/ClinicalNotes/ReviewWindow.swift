// ReviewWindow.swift
// macOS Local Speech-to-Text Application
//
// `NSWindow` host for `ReviewScreen` (#13). Mirrors the
// `MainWindow` / `MainWindowController` pattern: a singleton controller
// owned by `AppDelegate`-equivalent host code, with the view model
// constructed externally and passed into the SwiftUI root (the
// actor-existential mitigation pattern from
// `.claude/references/concurrency.md` §1).
//
// `AppState` configures the controller once on launch (`configure(...)`)
// with its own `SessionStore` + a bundle-loaded `ManipulationsRepository`,
// so callers can `present()` without further plumbing.

import AppKit
import Foundation
import OSLog
import SwiftUI

// MARK: - ReviewWindow

@MainActor
final class ReviewWindow: NSObject, NSWindowDelegate {
    // MARK: - Properties

    private var window: NSWindow?
    private let viewModel: ReviewViewModel

    private static let initialWidth: CGFloat = 1100
    private static let initialHeight: CGFloat = 720
    private static let minimumWidth: CGFloat = 880
    private static let minimumHeight: CGFloat = 560
    private static let windowTitle = "Clinical Notes Review"

    // MARK: - Init

    init(viewModel: ReviewViewModel) {
        self.viewModel = viewModel
        super.init()
    }

    // MARK: - Public

    /// Present the window and bring it to front.
    func show() {
        if window == nil {
            window = makeWindow()
        }
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Close + release the underlying NSWindow. Idempotent.
    func close() {
        window?.delegate = nil
        window?.close()
        window = nil
    }

    var isVisible: Bool {
        window?.isVisible ?? false
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // PHI chokepoint. Whatever path closed the window (Cancel, ⎋,
        // title-bar X, or a future export-flow auto-close), the session
        // does not survive the visible surface. `SessionStore.clear()`
        // is idempotent — `cancelReview` and the export-flow may have
        // already cleared, in which case this is a no-op. This satisfies
        // the AGENTS.md "PHI in-memory only, plus the HTTPS body at the
        // moment of POST to Cliniko" rule for the title-bar X path that
        // bypasses every in-app gesture.
        viewModel.sessionStore.clear()

        // Drop the delegate before clearing the reference (mirrors
        // MainWindow.swift HIGH-9 fix). Then notify the controller so it
        // can drop its strong ref and any further `.reviewScreenDidDismiss`
        // listeners (export-flow / AppState) get the close signal.
        window?.delegate = nil
        window = nil
        NotificationCenter.default.post(name: .reviewScreenDidDismiss, object: nil)
    }

    // MARK: - Private

    private func makeWindow() -> NSWindow {
        let newWindow = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: Self.initialWidth,
                height: Self.initialHeight
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        // #106 / #102 — disable AppKit's auto-release-on-close. Cancel
        // posts `.reviewScreenDidDismiss`, the controller observer hops
        // to MainActor and calls `window?.close()`, which fires
        // `windowWillClose` here, which posts `.reviewScreenDidDismiss`
        // a second time. The two MainActor Tasks queued from those two
        // posts can both observe `controller.window` non-nil and both
        // call `close()`. With the default `isReleasedWhenClosed = true`
        // that's an over-release; with `false`, lifetime is purely Swift
        // ARC and `close()` is just `orderOut:` — re-entry becomes safe.
        // (#102's "Cancel terminates the entire app" symptom is the same
        // over-release stomping `NSApplication`'s state on the next
        // runloop pool drain.)
        newWindow.isReleasedWhenClosed = false

        newWindow.delegate = self
        newWindow.title = Self.windowTitle
        newWindow.identifier = NSUserInterfaceItemIdentifier("reviewWindow")
        newWindow.titlebarAppearsTransparent = false
        newWindow.titleVisibility = .visible
        // PHI: window state restoration is OFF so transcript / draft note
        // content cannot survive in NSWindow restoration archives. See
        // AGENTS.md "PHI in-memory only" rule.
        newWindow.isRestorable = false
        newWindow.minSize = NSSize(width: Self.minimumWidth, height: Self.minimumHeight)
        // `.normal` (vs. the recording modal's `.floating`): this is a
        // long-form editor, not a transient capture overlay.
        newWindow.level = .normal
        newWindow.animationBehavior = .documentWindow

        let rootView = ReviewScreen(viewModel: viewModel)
        newWindow.contentView = NSHostingView(rootView: rootView)
        newWindow.center()

        return newWindow
    }
}

// MARK: - ReviewWindowController

/// Singleton controller for `ReviewWindow`. Configured once by
/// `AppState.init` with a `SessionStore` + `ManipulationsRepository`;
/// `.clinicalNotesGenerateRequested` triggers `present()`.
@MainActor
final class ReviewWindowController {
    // MARK: - Singleton

    static let shared = ReviewWindowController()

    // MARK: - Properties

    private var window: ReviewWindow?
    private var sessionStore: SessionStore?
    private var manipulations: ManipulationsRepository?
    /// Factory producing a fresh `ExportFlowViewModel` for each
    /// Export tap (#14). Returning `nil` means the
    /// `ExportFlowCoordinator` hasn't been configured (Cliniko not
    /// set up). The host's UI surfaces a structural banner in
    /// that case.
    ///
    /// `async` so the production wiring can `await` the Cliniko
    /// credentials load before reading the coordinator (#65). Test
    /// fixtures pass `{ nil }` — sync closures coerce to async.
    private var makeExportFlowViewModel: (() async -> ExportFlowViewModel?)?
    /// Factory for the header-hosted patient picker (#14).
    /// Returning `nil` has the same Cliniko-not-configured
    /// semantics as the export factory.
    private var makePatientPickerViewModel: (() async -> PatientPickerViewModel?)?
    private var dismissObserver: NSObjectProtocol?

    private let logger = Logger(
        subsystem: "com.speechtotext",
        category: "ReviewWindowController"
    )

    // MARK: - Init

    private init() {
        // Listen for dismiss so we drop the strong ref to the window when
        // it closes (whether via Cancel, ⎋, or the title-bar close button).
        // Mirrors the `mainWindowDidClose` pattern in `MainWindow.swift`.
        dismissObserver = NotificationCenter.default.addObserver(
            forName: .reviewScreenDidDismiss,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Notification handlers are not MainActor-isolated even with a
            // .main queue; hop explicitly so MainActor-isolated state is
            // safe to mutate per `.claude/references/concurrency.md` §2.
            Task { @MainActor [weak self] in
                self?.handleDismissNotification()
            }
        }
    }

    deinit {
        // Singleton: this `deinit` is unreachable in production. The
        // observer is registered for the process lifetime by design,
        // matching `MainWindowController.shared`. Cleanup runs only in
        // tests that recreate the singleton via reflection or in
        // hypothetical future de-singleton-isation.
        if let observer = dismissObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Configuration

    /// Wire the controller with its dependencies. Called once by
    /// `AppState.init`; subsequent calls overwrite (so tests / reset
    /// flows can reconfigure cleanly).
    ///
    /// The factory closures default to `{ nil }` so test wiring that
    /// only cares about the review surface (without exercising the
    /// export sheet) doesn't have to pass them explicitly. In
    /// production, AppState routes them to
    /// `ExportFlowCoordinator.shared.makeViewModel()` and a
    /// `PatientPickerViewModel` constructed against the configured
    /// Cliniko services.
    func configure(
        sessionStore: SessionStore,
        manipulations: ManipulationsRepository,
        makeExportFlowViewModel: @escaping () async -> ExportFlowViewModel? = { nil },
        makePatientPickerViewModel: @escaping () async -> PatientPickerViewModel? = { nil }
    ) {
        self.sessionStore = sessionStore
        self.manipulations = manipulations
        self.makeExportFlowViewModel = makeExportFlowViewModel
        self.makePatientPickerViewModel = makePatientPickerViewModel
    }

    /// Whether `configure(...)` has been called. Tests use this to
    /// guard against double-presentation in shared-state scenarios.
    var isConfigured: Bool {
        sessionStore != nil && manipulations != nil
    }

    // MARK: - Presentation

    /// Open the review window. Constructs the `ReviewViewModel` outside
    /// the SwiftUI root to mirror the actor-existential mitigation
    /// pattern in `LiquidGlassRecordingModal` / `RecordingViewModel`.
    func present() {
        guard let sessionStore, let manipulations else {
            // Configure-before-present is an AppState-init contract.
            // Surface as a structural log + assertion so misconfiguration
            // surfaces in DEBUG / tests without crashing release.
            logger.error("ReviewWindowController.present called before configure")
            assertionFailure("ReviewWindowController.present called before configure")
            return
        }

        // Idempotent: an existing window just gets brought forward.
        if let existing = window {
            existing.show()
            return
        }

        let viewModel = ReviewViewModel(
            sessionStore: sessionStore,
            manipulations: manipulations,
            makeExportFlowViewModel: makeExportFlowViewModel ?? { nil },
            makePatientPickerViewModel: makePatientPickerViewModel ?? { nil }
        )
        let newWindow = ReviewWindow(viewModel: viewModel)
        newWindow.show()
        window = newWindow
        logger.info("ReviewWindowController: presented review window")
    }

    /// Programmatically close the window. Triggers the same dismiss
    /// notification path as the user-initiated close.
    func close() {
        window?.close()
        window = nil
    }

    var isPresented: Bool {
        window?.isVisible ?? false
    }

    // MARK: - Private

    private func handleDismissNotification() {
        // Two paths converge here:
        //   1. User-driven cancel via `ReviewViewModel.cancelReview` —
        //      window is still alive, we must close it. `close()` fires
        //      AppKit's `windowWillClose`, which posts a second dismiss
        //      notification; the second pass through this handler hits
        //      the already-nil branch (no-op).
        //   2. Title-bar X / programmatic close — `windowWillClose` has
        //      already nilled `self.window`, so `close()` is a no-op.
        // Both ReviewWindow.close and NSWindow.close are idempotent.
        window?.close()
        window = nil
    }
}
