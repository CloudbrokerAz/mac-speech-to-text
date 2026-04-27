// SnapshotHost.swift
// macOS Local Speech-to-Text Application
//
// Shared helpers for `pointfreeco/swift-snapshot-testing` macOS image
// snapshots (issue #24 / F5). Centralises the `NSHostingView` wrap-and-
// size pattern so each test reads as "this view at this size in this
// appearance" without restating the boilerplate.
//
// Snapshot tests are deliberately scoped to ReviewScreen + SafetyDisclaimer
// — see `.claude/references/testing-conventions.md` and
// `Tests/SpeechToTextTests/Snapshots/README.md`.

import AppKit
import ObjectiveC
import SwiftUI

/// Wrap a SwiftUI view for `assertSnapshot(of:as: .image)`.
///
/// Three things have to be set up correctly before the library captures
/// a bitmap:
///
///   1. **Appearance.** `.preferredColorScheme(_:)` only propagates
///      through a `Window` / `Scene`; an `NSHostingView` outside any
///      window ignores the modifier. The escape hatch is to set
///      `appearance` on the hosting view directly.
///   2. **`onAppear` lifecycle.** SwiftUI only fires `.onAppear` once
///      its hosting view is in a window AND that window has been
///      ordered into the window list — merely setting `contentView`
///      isn't enough. Tests of views that gate visibility on an
///      onAppear-driven state flip (e.g. `SafetyDisclaimerView`'s
///      `isVisible: false → true` spring) get an always-initial-state
///      render without the order-in step.
///   3. **Animations.** `withAnimation { ... }` blocks inside `.onAppear`
///      schedule a multi-frame transition; capturing mid-flight produces
///      different pixels every run. We pump the runloop for `settleTime`
///      seconds so the spring runs to completion before the bitmap is
///      taken.
///
/// We position the window far offscreen so the order-in step doesn't
/// flash a window onto the user's display during a `swift test` run.
@MainActor
enum SnapshotHost {
    /// macOS appearance used by a snapshot. Maps to `NSAppearance.Name`.
    enum Appearance {
        case light
        case dark

        var nsAppearanceName: NSAppearance.Name {
            switch self {
            case .light: return .aqua
            case .dark: return .darkAqua
            }
        }
    }

    /// How long to pump the runloop after the window mounts, so any
    /// `.onAppear`-driven `withAnimation` block can run to its settled
    /// state. The longest animation in the snapshotted views is
    /// `SafetyDisclaimerView`'s spring `(response: 0.5, dampingFraction:
    /// 0.7)` — wall-clock settling is ~0.6s. Margin to 1.0s.
    private static let settleTime: TimeInterval = 1.0

    /// Build a sized, window-mounted `NSView` ready for `assertSnapshot`.
    ///
    /// Returns `NSView` (not the generic `NSHostingView<V>`) because the
    /// hosting type sometimes needs to wrap the input view in extra
    /// modifiers, which would change the generic. The library's
    /// image-snapshot strategy works against `NSView`, so dropping the
    /// generic at the call site is harmless.
    ///
    /// **Window lifetime.** AppKit retains the window via `NSApp.windows`
    /// once `orderFront` is called, but to make the lifetime explicit
    /// (and to keep the window alive deterministically even if AppKit's
    /// internal window list churns under `--parallel`), we attach the
    /// window as an Objective-C associated object on the returned
    /// hosting view. The window is released when the hosting view
    /// deinits — i.e. when the snapshot test scope ends.
    ///
    /// **`--parallel` safety.** `swift test --parallel` parallelises
    /// across processes, not threads, so each test gets its own
    /// `NSApplication` runloop. The runloop pump below is therefore
    /// safe against concurrent test execution.
    static func hosting<V: View>(
        _ view: V,
        size: CGSize,
        appearance: Appearance = .light
    ) -> NSView {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.appearance = NSAppearance(named: appearance.nsAppearanceName)

        // Position the temporary window far offscreen so an `orderFront`
        // call doesn't flash a window onto the user's display during
        // `swift test`. The desktop is unbounded in negative coords on
        // macOS, so any sufficiently-negative origin is safe.
        let offscreenOrigin = NSPoint(x: -50_000, y: -50_000)
        let window = NSWindow(
            contentRect: NSRect(origin: offscreenOrigin, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.orderFront(nil)

        // Pin the window's lifetime to the hosting view via an
        // associated object so callers don't have to thread the window
        // through manually. The OBJC_ASSOCIATION_RETAIN strength keeps
        // the window alive across the snapshot capture; the association
        // (and thus the window) drops when the hosting view deinits.
        objc_setAssociatedObject(
            hosting,
            &Self.windowAssociationKey,
            window,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )

        // Drive the SwiftUI lifecycle: order-in fires `.onAppear`, then
        // the spring animation runs over ~0.6s. Snapshotting before the
        // spring settles gives a different bitmap per run, so we pump
        // long enough for the animation to settle even on the first
        // (cold) test.
        //
        // `RunLoop.run(mode:before:)` returns `false` immediately if the
        // loop has no input sources to monitor — under that fall-through
        // the bare `while Date() < deadline { ... }` would busy-wait.
        // For the SwiftUI-driven case there are always sources (display
        // link, timer for the animation) so we don't actually hit the
        // hot path, but we sleep briefly on a `false` return for
        // belt-and-braces against any future change that drops the
        // animation source set.
        let deadline = Date(timeIntervalSinceNow: settleTime)
        while Date() < deadline {
            let chunkLimit = Date(timeIntervalSinceNow: 0.05)
            if RunLoop.current.run(mode: .default, before: chunkLimit) == false {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }

        // Force a layout pass so the hosting view's intrinsic size and
        // child frames are settled before the snapshot library captures
        // the bitmap. Belt-and-braces — the runloop pump above usually
        // covers this, but a final explicit layout protects against an
        // off-by-a-pixel race that resolves on the second test run.
        hosting.layoutSubtreeIfNeeded()

        return hosting
    }

    /// Storage key for the `objc_setAssociatedObject` window-lifetime
    /// pin. Only the address of this static is read — the value is
    /// never mutated and never read for content. The
    /// `nonisolated(unsafe)` annotation is justified per
    /// `.claude/references/concurrency.md` §3 (the project's mutable-
    /// global escape hatch): the byte is exclusively used as a stable
    /// runtime address by `objc_setAssociatedObject`, no concurrent
    /// reader inspects its value, and the Objective-C runtime
    /// internally synchronises the association table — so no Swift-
    /// level data race is possible.
    private nonisolated(unsafe) static var windowAssociationKey: UInt8 = 0
}
