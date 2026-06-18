import AppKit
import Foundation
import Testing
@testable import SpeechToText

@Suite("AppState PHI lifecycle wiring", .tags(.fast))
@MainActor
struct AppStatePHILifecycleTests {

    @Test("willTerminate notification clears active session")
    func willTerminate_clearsSessionStore() {
        let appState = AppState(llmPipelineOverride: .init(
            downloader: nil,
            provider: nil,
            processor: nil,
            manifest: nil
        ))
        appState.sessionStore.start(from: RecordingSession())
        #expect(appState.sessionStore.active != nil)

        NotificationCenter.default.post(
            name: NSApplication.willTerminateNotification,
            object: nil
        )

        #expect(appState.sessionStore.active == nil)
    }

    @Test("checkIdleTimeout clears session when elapsed beyond threshold")
    func idleTimeout_clearsSession() {
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
        let store = SessionStore(idleTimeout: 60, now: { clock.current })
        store.start(from: RecordingSession())
        clock.current = clock.current.addingTimeInterval(61)

        let cleared = store.checkIdleTimeout()
        #expect(cleared == true)
        #expect(store.active == nil)
    }

    private final class MutableClock: @unchecked Sendable {
        var current: Date
        init(_ start: Date) { current = start }
    }
}
