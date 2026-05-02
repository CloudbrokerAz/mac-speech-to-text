import Foundation

/// Builds the `User-Agent` header value Cliniko expects on every request
/// (see https://docs.api.cliniko.com/ + `.claude/references/cliniko-api.md`).
///
/// Cliniko's docs warn:
/// > "If your requests do not include a User-Agent that contains a name and
/// > valid contact email, future requests may be automatically blocked."
///
/// To honour that without baking a single hardcoded address into the source
/// (issue #89), the practitioner enters their own monitored email in the
/// Clinical Notes settings; it lives in `UserDefaults` under
/// `ClinikoCredentialStore.contactEmailUserDefaultsKey`. Two emitted shapes:
///
/// - **Configured (preferred):** `"mac-speech-to-text (user@example.com)"` —
///   matches the canonical `APP_VENDOR_NAME (APP_VENDOR_EMAIL)` form in
///   Cliniko's docs and the sibling reference integration
///   (`EpcLetterGenerator (support@epclettergen.app)` from
///   `epc-letter-generation`).
/// - **Fallback (no email yet):** `"mac-speech-to-text/<version>
///   (https://github.com/CloudbrokerAz/mac-speech-to-text)"`. The structural
///   contract — non-empty name + a contact reference — stays satisfied while
///   we wait for the doctor to set their email. The latent auto-block risk
///   Cliniko's docs warn about therefore only applies in the un-configured
///   window, not as a permanent regression.
public enum ClinikoUserAgent {
    /// App name component shared by both shapes. Centralised so a future
    /// rename only happens here.
    public static let appName = "mac-speech-to-text"

    /// Public repo URL — only used by the no-email fallback.
    public static let fallbackContactURL = "https://github.com/CloudbrokerAz/mac-speech-to-text"

    /// Build the header value. `contactEmail` is the trimmed value the user
    /// entered in Settings (or `nil` if unset). Whitespace-only inputs are
    /// treated as `nil` so an accidentally-saved blank field doesn't emit
    /// `"mac-speech-to-text ()"`.
    public static func make(contactEmail: String?) -> String {
        let trimmed = contactEmail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            return "\(appName) (\(trimmed))"
        }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        return "\(appName)/\(version) (\(fallbackContactURL))"
    }

    /// `@Sendable` closure suitable for `ClinikoClient` /
    /// `ClinikoAuthProbe`'s `userAgentProvider` parameter. Reads the email
    /// from `userDefaults` *per call* so a settings change propagates to
    /// the next request without re-instantiating either actor — important
    /// because a single `ClinikoClient` is shared by
    /// `ClinikoPatientService`, `ClinikoAppointmentService`, and
    /// `TreatmentNoteExporter` (see
    /// `AppState.configureClinikoExportPipelineIfNeeded`).
    ///
    /// The `userDefaults` parameter exists so tests can inject a per-suite
    /// `UserDefaults` and avoid mutating the shared standard suite — that
    /// would race `SessionStoreTests.lifecycle_doesNotTouchUserDefaults`
    /// under `swift test --parallel`. Production callers take the default.
    public static func defaultProvider(
        userDefaults: UserDefaults = .standard
    ) -> @Sendable () -> String {
        return { @Sendable [userDefaults] in
            ClinikoUserAgent.make(
                contactEmail: ClinikoCredentialStore.loadContactEmail(from: userDefaults)
            )
        }
    }
}
