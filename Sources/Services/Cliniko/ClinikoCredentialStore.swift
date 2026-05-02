import Foundation
import os.log

/// Persists Cliniko credentials. The API key goes to Keychain via the
/// `SecureStore` abstraction (#22 / F3); the shard goes to `UserDefaults`
/// because it is structural metadata, not a secret. Account / service /
/// UserDefaults key names are pinned in `.claude/references/cliniko-api.md`.
///
/// PHI / security:
/// - The API key value is **never** logged. Error-path logs reference the
///   service + account name + the *type* of the underlying error only —
///   never the error's stringified value (`String(describing: error)`),
///   because a future SecureStore failure type could carry user content.
/// - This store is the only path that reads or writes the Keychain item; the
///   raw key never round-trips back to the SwiftUI layer once stored.
///   Callers that need to make a request fetch a `ClinikoCredentials` value
///   directly and pass it to the HTTP client.
public actor ClinikoCredentialStore {
    /// Keychain `kSecAttrService` namespace shared by every Cliniko-related
    /// secret (currently only the API key, but reserved for future bearer
    /// tokens etc.). Matches `.claude/references/cliniko-api.md`.
    public static let serviceName = "com.speechtotext.cliniko"

    /// Keychain `kSecAttrAccount` for the API key.
    public static let apiKeyAccount = "api_key"

    /// `UserDefaults` key for the shard rawValue. Non-PHI structural value.
    public static let shardUserDefaultsKey = "cliniko.shard"

    /// `UserDefaults` key for the practitioner's contact email used in the
    /// `User-Agent` header sent to Cliniko (issue #89). Non-secret, doctor
    /// configurable from the Clinical Notes settings UI; lives alongside the
    /// shard rather than in Keychain because it is not authentication
    /// material — it is the contact reference Cliniko's docs require so they
    /// can reach the integration owner about abuse / incident.
    public static let contactEmailUserDefaultsKey = "cliniko.contactEmail"

    /// Errors surfaced from this store. Cases are semantic — callers can
    /// pattern-match on the operation that failed and inspect the wrapped
    /// `SecureStore` failure when they need the underlying `OSStatus`. This
    /// mirrors the direction of issue #29 ("split osStatus into semantic
    /// cases") at the next layer up.
    public enum Failure: Error, Sendable, CustomStringConvertible {
        case missingAPIKey
        case readFailed(underlying: any Error)
        case writeFailed(underlying: any Error)
        case deleteFailed(underlying: any Error)

        public var description: String {
            switch self {
            case .missingAPIKey:
                return "ClinikoCredentialStore: API key is empty"
            case .readFailed(let underlying):
                return "ClinikoCredentialStore: read failed (\(type(of: underlying)))"
            case .writeFailed(let underlying):
                return "ClinikoCredentialStore: write failed (\(type(of: underlying)))"
            case .deleteFailed(let underlying):
                return "ClinikoCredentialStore: delete failed (\(type(of: underlying)))"
            }
        }
    }

    private let secureStore: any SecureStore
    /// `UserDefaults` is documented thread-safe — every read/write is atomic
    /// from the caller's perspective. We mark it `nonisolated(unsafe)` so
    /// `loadShard` / `updateShard` can stay non-async; the picker binding in
    /// the settings UI then doesn't need an actor hop.
    nonisolated(unsafe) private let userDefaults: UserDefaults

    public init(
        secureStore: any SecureStore = KeychainSecureStore(service: ClinikoCredentialStore.serviceName),
        userDefaults: UserDefaults = .standard
    ) {
        self.secureStore = secureStore
        self.userDefaults = userDefaults
    }

    /// Returns the currently configured credentials, or `nil` if no API key
    /// is stored. The shard falls back to `ClinikoShard.default` when the
    /// stored value is missing or unrecognised (e.g. old install).
    public func loadCredentials() async throws -> ClinikoCredentials? {
        let key: String?
        do {
            key = try await secureStore.getString(forKey: Self.apiKeyAccount)
        } catch {
            // PHI rule: log the *type* of error, never `String(describing:)`
            // of the value itself (privacy: .public on a stringly-typed
            // payload would be a footgun the moment a SecureStore wraps a
            // body). Type names are structural and safe.
            AppLogger.service.error(
                "ClinikoCredentialStore.loadCredentials: SecureStore read failed type=\(String(describing: type(of: error)), privacy: .public)"
            )
            throw Failure.readFailed(underlying: error)
        }
        guard let trimmed = key.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }),
              !trimmed.isEmpty
        else {
            return nil
        }
        do {
            return try ClinikoCredentials(apiKey: trimmed, shard: loadShard())
        } catch {
            // Should be unreachable: `trimmed` is non-empty by the guard above.
            // Surface as a read failure so the caller can recover.
            throw Failure.readFailed(underlying: error)
        }
    }

    /// Lightweight presence check that avoids materialising the API key in
    /// the caller's memory. Used by the settings UI to render the connected /
    /// disconnected state without copying the secret.
    public func hasAPIKey() async throws -> Bool {
        do {
            let key = try await secureStore.getString(forKey: Self.apiKeyAccount)
            let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return !trimmed.isEmpty
        } catch {
            AppLogger.service.error(
                "ClinikoCredentialStore.hasAPIKey: SecureStore read failed type=\(String(describing: type(of: error)), privacy: .public)"
            )
            throw Failure.readFailed(underlying: error)
        }
    }

    /// Returns the persisted shard, or the default for new installs.
    /// Marked `nonisolated` because it only touches `UserDefaults` (thread-safe
    /// + immutable `let` reference) — keeps the SwiftUI picker binding fast.
    public nonisolated func loadShard() -> ClinikoShard {
        let raw = userDefaults.string(forKey: Self.shardUserDefaultsKey)
        return raw.flatMap(ClinikoShard.init(rawValue:)) ?? .default
    }

    /// Save (or replace) the API key + shard pair atomically from the
    /// caller's point of view. Trims whitespace and rejects empty input.
    /// The Keychain write happens before the UserDefaults write; on Keychain
    /// failure the shard is left untouched.
    public func saveCredentials(apiKey: String, shard: ClinikoShard) async throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.missingAPIKey }
        do {
            try await secureStore.setString(trimmed, forKey: Self.apiKeyAccount)
        } catch {
            AppLogger.service.error(
                "ClinikoCredentialStore.saveCredentials: SecureStore write failed type=\(String(describing: type(of: error)), privacy: .public)"
            )
            throw Failure.writeFailed(underlying: error)
        }
        userDefaults.set(shard.rawValue, forKey: Self.shardUserDefaultsKey)
    }

    /// Update only the shard. Useful when the user changes the picker without
    /// re-pasting the API key.
    /// Marked `nonisolated` for the same reason as `loadShard`: shard changes
    /// from the picker should not require an actor hop / `Task`.
    public nonisolated func updateShard(_ shard: ClinikoShard) {
        userDefaults.set(shard.rawValue, forKey: Self.shardUserDefaultsKey)
    }

    /// Returns the persisted contact email used in the Cliniko `User-Agent`
    /// header, or `nil` if unset / empty after trim. Marked `nonisolated`
    /// because the UA builder (called from inside `ClinikoClient` /
    /// `ClinikoAuthProbe` actors per request) must read it without an actor
    /// hop. Returning `nil` for whitespace-only input keeps the UA shape
    /// rule "if you set an email, you get the email form" honest.
    public nonisolated func loadContactEmail() -> String? {
        return Self.loadContactEmail(from: userDefaults)
    }

    /// Static convenience for callers that need the contact email without
    /// holding a `ClinikoCredentialStore` reference — used by
    /// `ClinikoUserAgent.defaultProvider()` so the UA-builder path doesn't
    /// instantiate a Keychain handle just to read a `UserDefaults` string.
    /// Returns `nil` if unset or whitespace-only after trim.
    public static func loadContactEmail(from userDefaults: UserDefaults) -> String? {
        let raw = userDefaults.string(forKey: contactEmailUserDefaultsKey)
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Persist the practitioner's contact email. Pass `nil` (or whitespace-
    /// only) to clear. Trims input. Marked `nonisolated` for the same reason
    /// as `loadContactEmail` — the settings TextField commit binding stays
    /// synchronous.
    ///
    /// Not cleared by `deleteCredentials`: the email is a preference about
    /// who Cliniko should contact, not material tied to the API key. A
    /// doctor who rotates their key shouldn't have to re-enter their own
    /// contact.
    public nonisolated func updateContactEmail(_ email: String?) {
        let trimmed = email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            userDefaults.removeObject(forKey: Self.contactEmailUserDefaultsKey)
        } else {
            userDefaults.set(trimmed, forKey: Self.contactEmailUserDefaultsKey)
        }
    }

    /// Delete every Cliniko credential and forget the shard. The Keychain
    /// delete runs first; only on success do we clear the shard. This keeps
    /// the on-disk pair consistent across failure modes:
    ///
    /// - Keychain delete **fails** → key + shard both remain. `loadCredentials`
    ///   still returns a usable pair pointed at the correct tenant, so a user
    ///   who retries (or who chooses to keep using Cliniko while we sort out
    ///   the Keychain error) hits the right shard.
    /// - Keychain delete **succeeds** → shard cleared. No stale tenant
    ///   reference outlives the secret it authenticated against.
    ///
    /// The reverse asymmetry (Keychain succeeds + UserDefaults remove fails)
    /// is a non-failure mode in practice — `UserDefaults.removeObject` is a
    /// documented thread-safe call with no failure path on a writable suite.
    public func deleteCredentials() async throws {
        do {
            try await secureStore.delete(forKey: Self.apiKeyAccount)
        } catch {
            AppLogger.service.error(
                "ClinikoCredentialStore.deleteCredentials: SecureStore delete failed type=\(String(describing: type(of: error)), privacy: .public)"
            )
            throw Failure.deleteFailed(underlying: error)
        }
        userDefaults.removeObject(forKey: Self.shardUserDefaultsKey)
    }
}
