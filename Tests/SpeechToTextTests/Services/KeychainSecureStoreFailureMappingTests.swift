import Foundation
import Security
import Testing
@testable import SpeechToText

// Pure-logic tests for `KeychainSecureStore.Failure.from(status:op:)`.
//
// The `.requiresHardware` round-trip suite in `KeychainSecureStoreTests`
// can't reach this mapping without fault-injecting raw `SecItem*`
// returns. Splitting the OSStatus → semantic-case table out into a
// pure helper made it directly testable — these run in CI under the
// `.fast` tag and pin the contract that callers rely on (switch on
// the case, never on the raw status integer).

@Suite("KeychainSecureStore.Failure.from(status:op:)", .tags(.fast))
struct KeychainSecureStoreFailureMappingTests {

    typealias Failure = KeychainSecureStore.Failure
    typealias Operation = KeychainSecureStore.Failure.Operation

    // MARK: - authDenied family

    @Test(
        "Auth-denied / cancelled OSStatuses map to .authDenied",
        arguments: [
            errSecInteractionNotAllowed,
            errSecAuthFailed,
            errSecUserCanceled
        ]
    )
    func authDeniedFamily_mapsToAuthDenied(status: OSStatus) {
        #expect(Failure.from(status: status, op: .get) == .authDenied(.get))
    }

    // MARK: - notAvailable family

    @Test(
        "Not-available OSStatuses map to .notAvailable",
        arguments: [
            errSecNotAvailable,
            errSecMissingEntitlement
        ]
    )
    func notAvailableFamily_mapsToNotAvailable(status: OSStatus) {
        #expect(Failure.from(status: status, op: .set) == .notAvailable(.set))
    }

    // MARK: - corrupted family

    /// `errSecDecode` indicates the keychain item exists but cannot be
    /// decoded — for a credential store this is probable corruption of
    /// the secret payload. Maps to `.corrupted` so the UI can surface
    /// "your stored credentials look corrupt; please re-enter the API
    /// key" rather than the generic `OSStatus -26275` description.
    @Test(
        "Decode-failure OSStatus maps to .corrupted",
        arguments: [
            errSecDecode
        ]
    )
    func corruptedFamily_mapsToCorrupted(status: OSStatus) {
        #expect(Failure.from(status: status, op: .get) == .corrupted(.get))
    }

    // MARK: - unmapped → unexpected

    /// Any OSStatus the helper doesn't recognise must surface as
    /// `unexpected`, carrying the raw status for diagnostics. The point
    /// of the encapsulation is that callers don't need to interpret
    /// these — but the integer is still useful in `OSLog` for support.
    ///
    /// `errSecDecode` was previously in this list — it now has its own
    /// `.corrupted` case (see the family suite above). `errSecInternalError`
    /// is no longer a deleteAll-cap-exceeded sentinel either: that path
    /// throws `.loopCapExceeded(.deleteAll)` directly without going
    /// through `Failure.from(...)`, so the mapping is back to a clean
    /// "we genuinely got this status from Keychain" semantics.
    @Test(
        "Unmapped OSStatuses fall through to .unexpected, preserving the raw status",
        arguments: [
            errSecItemNotFound,           // intercepted at call site, but mapping must still be defined
            errSecDuplicateItem,          // handled inline in addItem retry path
            errSecInternalError,          // a real Keychain return — no longer doubles as a deleteAll-cap sentinel
            errSecParam,                  // programmer-error class
            OSStatus(-99999)              // arbitrary unknown
        ]
    )
    func unmappedStatus_mapsToUnexpected(status: OSStatus) {
        let mapped = Failure.from(status: status, op: .delete)
        #expect(mapped == .unexpected(status, .delete))
    }

    // MARK: - Operation propagation

    /// The helper must thread the `Operation` argument through to the
    /// resulting case unchanged across every branch. A regression here
    /// would make every error claim `.set` regardless of where it was
    /// thrown from.
    @Test(
        "Operation propagates through every mapping branch",
        arguments: [
            Operation.set, .get, .delete, .deleteAll
        ]
    )
    func operationIsPropagated(op: Operation) {
        #expect(Failure.from(status: errSecAuthFailed, op: op) == .authDenied(op))
        #expect(Failure.from(status: errSecNotAvailable, op: op) == .notAvailable(op))
        #expect(Failure.from(status: errSecParam, op: op) == .unexpected(errSecParam, op))
    }

    // MARK: - Operation propagation, corrupted branch

    /// Same propagation contract as `operationIsPropagated` above — but
    /// for the `.corrupted` branch, which the original test predates.
    @Test(
        "Operation propagates through .corrupted branch",
        arguments: [
            Operation.set, .get, .delete, .deleteAll
        ]
    )
    func operationIsPropagated_corrupted(op: Operation) {
        #expect(Failure.from(status: errSecDecode, op: op) == .corrupted(op))
    }

    // MARK: - description

    /// Every case must emit a distinct, op-tagged description — useful
    /// in error logs and `Error.localizedDescription` (now that
    /// `LocalizedError` conformance routes through `description`).
    /// Pinning the strings is intentional: a future "let's tidy these
    /// up" refactor can update the goldens deliberately rather than
    /// silently shifting support-team-facing copy.
    @Test("Description text for each case")
    func descriptionForEachCase() {
        #expect(
            Failure.authDenied(.get).description
                == "KeychainSecureStore: get failed (auth denied / cancelled)"
        )
        #expect(
            Failure.notAvailable(.set).description
                == "KeychainSecureStore: set failed (keychain not available)"
        )
        #expect(
            Failure.unexpectedItemType(.get).description
                == "KeychainSecureStore: get returned a non-Data item"
        )
        #expect(
            Failure.corrupted(.get).description
                == "KeychainSecureStore: get failed (stored item is corrupt — re-enter credentials)"
        )
        #expect(
            Failure.loopCapExceeded(.deleteAll).description
                == "KeychainSecureStore: deleteAll couldn't finish — please restart the app and try again"
        )
        #expect(
            Failure.unexpected(errSecParam, .delete).description
                == "KeychainSecureStore: delete failed (OSStatus -50)"
        )
    }

    // MARK: - loopCapExceeded is constructed at the call site, not via .from

    /// `.loopCapExceeded` is the one case that bypasses
    /// `Failure.from(status:op:)` — it's constructed directly in
    /// `KeychainSecureStore.deleteAll()` when the 10 000-iteration cap
    /// is hit, and no real `OSStatus` is in flight. This negative test
    /// pins that invariant: no input to `.from(...)` should ever yield
    /// `.loopCapExceeded`. A regression here would mean someone slipped
    /// an `OSStatus → .loopCapExceeded` mapping into the helper, which
    /// would muddy the case's "we wedged" semantics with a Keychain
    /// status that has its own meaning.
    @Test(
        "Failure.from never produces .loopCapExceeded",
        arguments: [
            errSecSuccess,
            errSecItemNotFound,
            errSecDuplicateItem,
            errSecInternalError,                     // the integer the synthetic sentinel previously borrowed
            errSecAuthFailed,
            errSecNotAvailable,
            errSecDecode,
            errSecParam,
            OSStatus(-99999)
        ]
    )
    func loopCapExceededIsNeverProducedByFrom(status: OSStatus) {
        for op: Operation in [.set, .get, .delete, .deleteAll] {
            let mapped = Failure.from(status: status, op: op)
            #expect(
                mapped != .loopCapExceeded(op),
                ".from(status: \(status), op: \(op)) must not produce .loopCapExceeded"
            )
        }
    }

    // MARK: - LocalizedError

    /// `LocalizedError` conformance routes `errorDescription` through
    /// `description`. Without this, casting a `Failure` back to the
    /// existential `any Error` (which `throws` propagation does) loses
    /// the typed copy and SwiftUI / AppKit alert UIs surface Apple's
    /// generic "The operation couldn't be completed. (... error 1.)"
    /// fallback. One representative case is enough — the conformance
    /// is a single-line passthrough.
    @Test("LocalizedError.errorDescription matches description")
    func localizedErrorDescriptionMatchesDescription() {
        let failure = Failure.corrupted(.get)
        #expect(failure.errorDescription == failure.description)
        // Belt-and-braces: also check the existential cast that real
        // call sites take. `localizedDescription` is the property that
        // `Alert(error:)` / `NSAlert` actually read.
        let asError: any Error = failure
        #expect(asError.localizedDescription == failure.description)
    }
}
