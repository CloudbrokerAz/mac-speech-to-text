// MainWindow.swift
// macOS Local Speech-to-Text Application
//
// Phase 2: Unified Main View
// NSWindow wrapper for MainView with standard macOS window behavior

import AppKit
import SwiftUI

// MARK: - MainWindow

/// NSWindow wrapper that hosts the MainView
/// Provides standard macOS window behavior with title bar and traffic lights
@MainActor
final class MainWindow: NSObject, NSWindowDelegate {
    // MARK: - Properties

    /// The underlying NSWindow
    private var window: NSWindow?

    /// The ViewModel shared between window and view
    private let viewModel: MainViewModel

    /// Dependencies for sections
    private let settingsService: SettingsService
    private let permissionService: PermissionService

    /// Optional Gemma 4 model status surface (#104). Routed through
    /// `MainView` → `ClinicalNotesSection`. `nil` for tests + the
    /// fallback `MainWindowController.shared` constructions where
    /// AppState hasn't called `configure(...)` yet.
    private let modelStatusViewModel: ClinicalNotesModelStatusViewModel?

    /// Window dimensions
    private static let windowWidth: CGFloat = 900
    private static let windowHeight: CGFloat = 820

    /// Window title
    private static let windowTitle = "Speech to Text"

    // MARK: - Initialization

    init(
        viewModel: MainViewModel = MainViewModel(),
        settingsService: SettingsService = SettingsService(),
        permissionService: PermissionService = PermissionService(),
        modelStatusViewModel: ClinicalNotesModelStatusViewModel? = nil
    ) {
        self.viewModel = viewModel
        self.settingsService = settingsService
        self.permissionService = permissionService
        self.modelStatusViewModel = modelStatusViewModel
        super.init()
    }

    deinit {
        // Window cleanup is handled by close()
    }

    // MARK: - Public Methods

    /// Show the main window
    func show() {
        guard window == nil else {
            // Window already exists, just bring to front
            // Activate app first, then make window key (important for menu bar apps)
            NSApp.activate(ignoringOtherApps: true)
            window?.deminiaturize(nil)  // Un-minimize if minimized
            window?.makeKeyAndOrderFront(nil)
            return
        }

        // Create the SwiftUI view with pre-created ViewModel and dependencies
        let mainView = MainView(
            viewModel: viewModel,
            settingsService: settingsService,
            permissionService: permissionService,
            modelStatusViewModel: modelStatusViewModel
        )

        // Create the window with standard macOS chrome
        let newWindow = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: Self.windowWidth,
                height: Self.windowHeight
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        // #106 / #102 — disable AppKit's auto-release-on-close. With the
        // default `true`, `close()` autoreleases the NSWindow in addition
        // to whatever Swift ARC does via our strong `window` property.
        // Any second `close()` (from a re-entrant notification observer,
        // SwiftUI `.onDisappear`, or termination cleanup) then sends
        // `release` to a deallocated `NSKVONotifying_NSWindow` — the
        // exact zombie NSZombies caught for #106. Setting `false` puts
        // lifetime entirely under Swift ARC and makes `close()` idempotent.
        newWindow.isReleasedWhenClosed = false

        // Configure window
        configureWindow(newWindow)

        // Set content view
        newWindow.contentView = NSHostingView(rootView: mainView)

        // Center and show window (activate app first for menu bar apps)
        newWindow.center()
        NSApp.activate(ignoringOtherApps: true)
        newWindow.makeKeyAndOrderFront(nil)

        window = newWindow
    }

    /// Hide the main window
    func hide() {
        window?.orderOut(nil)
    }

    /// Close and release the window
    /// Note: Delegate is nil'd before closing to prevent callbacks during deallocation (CRIT-5, HIGH-10)
    func close() {
        window?.delegate = nil
        window?.close()
        window = nil
    }

    /// Toggle window visibility
    func toggle() {
        if let existingWindow = window, existingWindow.isVisible {
            hide()
        } else {
            show()
        }
    }

    /// Check if window is currently visible
    var isVisible: Bool {
        window?.isVisible ?? false
    }

    /// Navigate to a specific section
    func navigateTo(_ section: SidebarSection) {
        viewModel.navigateTo(section)
        show()
    }

    // MARK: - Private Methods

    /// Configure window appearance and behavior
    private func configureWindow(_ window: NSWindow) {
        // Set delegate to receive window events
        window.delegate = self

        // Window title
        window.title = Self.windowTitle
        window.identifier = NSUserInterfaceItemIdentifier("mainWindow")

        // Standard window appearance
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible

        // Don't restore position on relaunch
        window.isRestorable = false

        // Set minimum size
        window.minSize = NSSize(width: Self.windowWidth, height: Self.windowHeight)

        // Standard window level
        window.level = .normal

        // Close button behavior
        window.standardWindowButton(.closeButton)?.isEnabled = true
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = true
        window.standardWindowButton(.zoomButton)?.isEnabled = true

        // Animation behavior
        window.animationBehavior = .documentWindow
    }

    // MARK: - NSWindowDelegate

    /// Called when window is about to close - clears reference to prevent stale state
    /// Note: Delegate nil'd to break retain cycle before clearing window reference (HIGH-9)
    func windowWillClose(_ notification: Notification) {
        window?.delegate = nil
        window = nil
        // Notify controller to release MainWindow reference, preventing stale state
        NotificationCenter.default.post(name: .mainWindowDidClose, object: nil)
    }
}

// MARK: - MainWindowController

/// Controller for managing MainWindow lifecycle
/// Use this to integrate with AppDelegate or other window management
@MainActor
final class MainWindowController {
    // MARK: - Singleton

    static let shared = MainWindowController()

    // MARK: - Properties

    private var mainWindow: MainWindow?

    /// Observer for window close notifications
    private var windowCloseObserver: NSObjectProtocol?

    /// Cached Gemma 4 model status VM (#104). Captured once via
    /// `configure(modelStatusViewModel:)` from `AppState.init` and threaded
    /// into every `MainWindow` constructed here. Defaults to `nil` so
    /// any pre-configure window construction (tests, defensive paths)
    /// still works — the `ClinicalNotesSection` row hides when this is nil.
    private var modelStatusViewModel: ClinicalNotesModelStatusViewModel?

    // MARK: - Initialization

    private init() {
        // Listen for window close to clean up MainWindow reference (HIGH-9)
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: .mainWindowDidClose,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.mainWindow = nil
            }
        }
    }

    deinit {
        if let observer = windowCloseObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Public Methods

    /// Wire the controller with cross-window dependencies that can't be
    /// reached at MainWindow's construction site (tests, AppDelegate).
    /// Called once by `AppState.init`; subsequent calls overwrite, mirroring
    /// `ReviewWindowController.shared.configure(...)`.
    ///
    /// A second call replaces the cached VM, but any already-presented
    /// `MainWindow` was constructed with the first VM and continues to
    /// bind against that — so a clobber after a window is open silently
    /// goes stale on screen. Surface a structural warning so a regression
    /// here is debuggable; in production this is a singleton path called
    /// exactly once from `AppState.init`.
    func configure(modelStatusViewModel: ClinicalNotesModelStatusViewModel) {
        if self.modelStatusViewModel != nil,
           self.modelStatusViewModel !== modelStatusViewModel {
            AppLogger.app.warning(
                "MainWindowController.configure: replacing live modelStatusViewModel — open windows may bind to stale VM"
            )
        }
        self.modelStatusViewModel = modelStatusViewModel
    }

    /// Show the main window
    func showWindow() {
        if mainWindow == nil {
            mainWindow = makeMainWindow()
        }
        mainWindow?.show()
    }

    /// Hide the main window
    func hideWindow() {
        mainWindow?.hide()
    }

    /// Close and release the main window
    func closeWindow() {
        mainWindow?.close()
        mainWindow = nil
    }

    /// Toggle main window visibility
    func toggleWindow() {
        if mainWindow == nil {
            mainWindow = makeMainWindow()
        }
        mainWindow?.toggle()
    }

    /// Check if window is visible
    var isWindowVisible: Bool {
        mainWindow?.isVisible ?? false
    }

    /// Navigate to a specific section and show window
    func showSection(_ section: SidebarSection) {
        if mainWindow == nil {
            mainWindow = makeMainWindow()
        }
        mainWindow?.navigateTo(section)
    }

    /// Show window with Settings (General) section pre-selected
    /// Called when user presses Cmd+, or clicks Settings
    func showSettings() {
        showSection(.general)
    }

    // MARK: - Private

    /// Construct a `MainWindow` with the configured cross-window
    /// dependencies threaded in. Pulled out so every `mainWindow == nil`
    /// branch above gets the same wiring.
    private func makeMainWindow() -> MainWindow {
        MainWindow(modelStatusViewModel: modelStatusViewModel)
    }
}

// MARK: - Notification Extension

extension Notification.Name {
    /// Posted when the main window should be shown
    static let showMainWindow = Notification.Name("showMainWindow")

    /// Posted when the main window should navigate to a specific section
    static let navigateToSection = Notification.Name("navigateToSection")

    /// Posted when the main window has closed (for cleanup)
    static let mainWindowDidClose = Notification.Name("mainWindowDidClose")
}
