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

    // MARK: - unmapped → unexpected

    /// Any OSStatus the helper doesn't recognise must surface as
    /// `unexpected`, carrying the raw status for diagnostics. The point
    /// of the encapsulation is that callers don't need to interpret
    /// these — but the integer is still useful in `OSLog` for support.
    @Test(
        "Unmapped OSStatuses fall through to .unexpected, preserving the raw status",
        arguments: [
            errSecItemNotFound,           // intercepted at call site, but mapping must still be defined
            errSecDuplicateItem,          // handled inline in addItem retry path
            errSecInternalError,          // also our synthetic deleteAll-loop sentinel
            errSecParam,                  // programmer-error class
            errSecDecode,                 // Keychain corruption sentinel — promote to a `.corrupted` case if a caller ever needs to distinguish it
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

    // MARK: - description

    /// The four cases must each emit a distinct, op-tagged description
    /// — useful in error logs and `Error.localizedDescription`. Pinning
    /// the strings is intentional: a future "let's tidy these up" refactor
    /// can update the goldens deliberately rather than silently shifting
    /// support-team-facing copy.
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
            Failure.unexpected(errSecParam, .delete).description
                == "KeychainSecureStore: delete failed (OSStatus -50)"
        )
    }
}
