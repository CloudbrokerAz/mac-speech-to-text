// ClinicalNotesSection.swift
// macOS Local Speech-to-Text Application
//
// Clinical Notes Mode toggle (#11) + Cliniko credentials (#7). The toggle is
// gated on the credentials being present — see `viewModel.hasStoredCredentials`
// (AC4 of #7). Disabling the toggle is one click; un-storing credentials also
// implicitly disables the experience.

import SwiftUI

/// Settings section for Clinical Notes Mode + Cliniko credentials. The doctor
/// flips Clinical Notes Mode on, pastes their Cliniko API key, picks the
/// regional shard, optionally tests the connection, and can clear credentials.
/// Per `.claude/references/cliniko-api.md` the key is stored in Keychain via
/// `ClinikoCredentialStore`; the shard goes to `UserDefaults`.
struct ClinicalNotesSection: View {
    @Bindable var viewModel: ClinicalNotesSectionViewModel

    // MARK: - Dependencies

    let settingsService: SettingsService

    // MARK: - State

    @State private var settings: UserSettings
    @State private var saveError: String?
    @State private var errorDismissalTask: Task<Void, Never>?

    // MARK: - Initialisation

    init(
        viewModel: ClinicalNotesSectionViewModel,
        settingsService: SettingsService = SettingsService()
    ) {
        self.viewModel = viewModel
        self.settingsService = settingsService
        self._settings = State(initialValue: settingsService.load())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let error = saveError {
                    saveErrorBanner(message: error)
                }

                sectionHeader

                clinicalNotesModeRow

                connectionStatusCard

                Divider().padding(.vertical, 4)

                apiKeyEntrySection

                shardPickerSection

                actionButtons

                if let message = viewModel.statusMessage {
                    statusBanner(message: message, kind: viewModel.connectionStatus)
                }

                Spacer(minLength: 20)

                privacyFooter
            }
            .padding(20)
            .animation(.easeInOut(duration: 0.3), value: saveError)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("clinicalNotesSection")
        .task {
            await viewModel.refreshState()
            // Reload settings on appear so a toggle change made elsewhere is
            // reflected the next time the user lands here.
            settings = settingsService.load()
        }
        .onDisappear {
            errorDismissalTask?.cancel()
            errorDismissalTask = nil
        }
        .onChange(of: viewModel.credentialState) { _, newValue in
            // If the doctor removes credentials, force the toggle off so
            // Clinical Notes Mode can never appear "on" without a tenant to
            // export to. Persist immediately so a quit before a save still
            // disables the mode.
            //
            // Bypasses `applyClinicalNotesMode(_:)` deliberately: that
            // helper resets the Safety Disclaimer ack on off→on
            // transitions (#12), and a credential-removal force-off is
            // not a re-enable gesture. `applyClinicalNotesMode(false)`
            // would short-circuit the reset anyway, but the direct write
            // makes the intent unambiguous at the call site.
            guard newValue == .absent, settings.general.clinicalNotesModeEnabled else { return }
            settings.general.clinicalNotesModeEnabled = false
            saveSettings()
        }
    }

    // MARK: - Section Header

    private var sectionHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Clinical Notes")
                .font(.title2)
                .fontWeight(.semibold)
                .accessibilityAddTraits(.isHeader)

            Text("Cliniko credentials and clinical-notes export")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("clinicalNotesSection.header")
    }

    // MARK: - Clinical Notes Mode Toggle

    /// The mode toggle is gated on `hasStoredCredentials`: we do not let the
    /// doctor enable Clinical Notes Mode without a Cliniko tenant configured,
    /// because the post-recording "Generate Notes" flow ends in a Cliniko
    /// POST. The card explains this when the toggle is disabled, so the user
    /// is not left guessing why the switch won't move.
    private var clinicalNotesModeRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: clinicalNotesModeBinding) {
                HStack(spacing: 12) {
                    Image(systemName: "stethoscope")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.iconPrimaryAdaptive)
                        .frame(width: 24)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Clinical Notes Mode")
                            .font(.body)
                            .foregroundStyle(.primary)

                        Text("Generate structured SOAP notes after each recording")
                            .font(.caption)
                            .foregroundStyle(Color.textTertiaryAdaptive)
                    }
                }
            }
            .toggleStyle(.switch)
            .disabled(!viewModel.hasStoredCredentials)
            .padding(.vertical, 4)
            .accessibilityIdentifier("clinicalNotesModeToggle")
            .accessibilityLabel("Clinical Notes Mode. Generate structured SOAP notes after each recording.")

            if !viewModel.hasStoredCredentials {
                Text("Add your Cliniko credentials below to enable Clinical Notes Mode.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .accessibilityIdentifier("clinicalNotesModeToggle.disabledHint")
            }
        }
    }

    private var clinicalNotesModeBinding: Binding<Bool> {
        Binding(
            get: { settings.general.clinicalNotesModeEnabled },
            set: { newValue in
                // Apply via the model helper so off→on transitions reset the
                // Safety Disclaimer ack (#12 AC item 3). The helper leaves
                // the flag alone on on→off and on→on, matching the spec
                // "resets if user disables and re-enables Clinical Notes
                // Mode."
                settings.general.applyClinicalNotesMode(newValue)
                saveSettings()
            }
        )
    }

    // MARK: - Save error banner

    private func saveErrorBanner(message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.white)
            Text(message)
                .font(.callout)
                .foregroundStyle(.white)
            Spacer()
        }
        .padding(12)
        .background(Color.red.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityIdentifier("clinicalNotesSection.saveErrorBanner")
    }

    // MARK: - Connection Status Card

    private var connectionStatusCard: some View {
        let display = viewModel.statusCardDisplay
        return HStack(spacing: 16) {
            Image(systemName: display.icon)
                .font(.system(size: 28))
                .foregroundStyle(display.tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(display.title)
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text(display.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(display.tint.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("clinicalNotesSection.statusCard")
    }

    // MARK: - API Key Entry

    private var apiKeyEntrySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("API key")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)

            SecureField(
                viewModel.hasStoredCredentials ? "•••••••• (paste a new key to replace)" : "Paste your Cliniko API key",
                text: $viewModel.apiKeyDraft
            )
            .textFieldStyle(.roundedBorder)
            .disableAutocorrection(true)
            .accessibilityIdentifier("clinicalNotesSection.apiKeyField")

            Text("Find this in Cliniko under My Info → Manage API keys. The key is stored in macOS Keychain on this Mac only.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Shard Picker

    private var shardPickerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Region (shard)")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)

            Picker("Shard", selection: $viewModel.selectedShard) {
                ForEach(ClinikoShard.allCases) { shard in
                    Text(shard.displayName).tag(shard)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .accessibilityIdentifier("clinicalNotesSection.shardPicker")

            Text("Pick the region your Cliniko tenant is hosted in. The shard is part of your account URL (e.g. au1 in `cliniko.com.au/...`).")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button {
                Task { await viewModel.saveAndTest() }
            } label: {
                Label(
                    viewModel.hasStoredCredentials ? "Update & test" : "Save & test connection",
                    systemImage: "checkmark.seal"
                )
                .frame(minWidth: 0)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.warmAmber)
            .disabled(viewModel.isBusy || !viewModel.isApiKeyDraftValid)
            .accessibilityIdentifier("clinicalNotesSection.saveButton")

            Button {
                Task { await viewModel.testConnection() }
            } label: {
                Label("Test connection", systemImage: "antenna.radiowaves.left.and.right")
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isBusy || !viewModel.hasStoredCredentials)
            .accessibilityIdentifier("clinicalNotesSection.testButton")

            Spacer()

            Button(role: .destructive) {
                Task { await viewModel.removeCredentials() }
            } label: {
                Label("Remove", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isBusy || !viewModel.hasStoredCredentials)
            .accessibilityIdentifier("clinicalNotesSection.removeButton")
        }
    }

    // MARK: - Status Banner

    @ViewBuilder
    private func statusBanner(message: String, kind: ClinicalNotesSectionViewModel.ConnectionStatus) -> some View {
        let (icon, tint): (String, Color) = {
            switch kind {
            case .testing: return ("hourglass", Color.secondary)
            case .success: return ("checkmark.circle.fill", Color.successGreen)
            case .failure: return ("exclamationmark.triangle.fill", Color.red)
            case .idle: return ("info.circle", Color.secondary)
            }
        }()

        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(message)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(12)
        .background(tint.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("clinicalNotesSection.statusBanner")
    }

    // MARK: - Persistence

    private func saveSettings() {
        do {
            try settingsService.save(settings)
            saveError = nil
        } catch {
            // Log the structural error class so a developer reading
            // sysdiagnose can distinguish encoder failure from UserDefaults
            // write failure. Never log `error.localizedDescription` directly
            // — settings are PHI-adjacent (no PHI in the schema today, but
            // the field set evolves). See `.claude/references/phi-handling.md`.
            AppLogger.service.error(
                "ClinicalNotesSection: settings save failed kind=\(String(describing: type(of: error)), privacy: .public)"
            )
            // Reload to drop the optimistic mutation so the UI reflects what
            // is actually persisted. Then surface a transient banner.
            settings = settingsService.load()
            showSaveError("Could not save the Clinical Notes Mode setting. Please try again.")
        }
    }

    private func showSaveError(_ message: String) {
        saveError = message
        errorDismissalTask?.cancel()
        errorDismissalTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled {
                saveError = nil
            }
        }
    }

    // MARK: - Privacy Footer

    private var privacyFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            HStack(spacing: 4) {
                Image(systemName: "checkmark.shield")
                    .font(.caption)
                    .foregroundStyle(Color.successGreen)

                Text("Your patient data stays on this Mac")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Transcripts and notes are kept in memory only and cleared on export or quit. The only network call goes from this Mac directly to your Cliniko tenant.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("clinicalNotesSection.privacyFooter")
    }
}

// MARK: - ViewModel

/// State + side-effects for `ClinicalNotesSection`. Owns a
/// `ClinikoCredentialStore` and `ClinikoAuthProbe`; never reads the API key
/// back from Keychain into VM-visible state. Both dependencies are actor
/// existentials and live behind `@ObservationIgnored` per the project's
/// concurrency rule (`@Observable` + actor existential without
/// `@ObservationIgnored` crashes; see `.claude/references/concurrency.md`).
@Observable
@MainActor
final class ClinicalNotesSectionViewModel {
    /// Outcome of the most recent network probe + transient testing state.
    /// Drives the status banner only — the *card* uses `verificationStatus`
    /// so a save without a successful probe doesn't render as "verified".
    enum ConnectionStatus: Equatable {
        case idle
        case testing
        case success
        case failure
    }

    /// What `hasAPIKey()` last reported. Distinguishes "Keychain says absent"
    /// from "Keychain read errored" so #11's Clinical Notes Mode toggle
    /// won't silently disable itself when the Keychain is transiently locked.
    enum CredentialLoadState: Equatable {
        case unknown
        case present
        case absent
        case readFailed
    }

    /// Whether the credentials currently in the store have been verified
    /// against Cliniko by a successful probe in this app session. The status
    /// card derives its colour + message from this — saving alone doesn't
    /// flip the card to "verified".
    enum VerificationStatus: Equatable {
        case absent
        case unverified
        case verified
        case readError
    }

    /// The user's in-flight API-key input. Cleared after a successful save so
    /// the secret only lives in VM memory for the duration of the entry.
    var apiKeyDraft: String = ""

    /// Whether the current draft is non-empty after trimming. Centralises the
    /// "is the save button enabled" check so both the view's button and the
    /// VM's `saveAndTest` guard apply the same rule.
    var isApiKeyDraftValid: Bool {
        !apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Picker selection. Changes are persisted to UserDefaults via the store
    /// when the user hits Save; merely changing the picker without saving is
    /// reverted on next refresh.
    var selectedShard: ClinikoShard = .default {
        didSet {
            guard oldValue != selectedShard, hasStoredCredentials, !isApplyingExternalUpdate else { return }
            // Persist shard changes immediately when credentials already exist —
            // no need to re-enter the API key for a region change. The store's
            // `updateShard` is `nonisolated` so this stays a synchronous call.
            credentialStore.updateShard(selectedShard)
            // Re-pointing at a different tenant invalidates any prior probe.
            verificationStatus = .unverified
        }
    }

    private(set) var credentialState: CredentialLoadState = .unknown
    private(set) var verificationStatus: VerificationStatus = .absent
    private(set) var connectionStatus: ConnectionStatus = .idle
    private(set) var statusMessage: String?
    private(set) var isBusy: Bool = false

    /// Convenience flag for #11 to gate the Clinical Notes Mode toggle on,
    /// and for the view to gate the Remove / Test buttons. Returns `true`
    /// when we have either positively confirmed credentials OR a Keychain
    /// read error has prevented us from telling — both of those mean
    /// "credentials may exist on this device", so the user must be allowed
    /// to click Remove (otherwise the banner's own "Try removing and
    /// re-adding your API key" advice becomes a UX deadlock when the
    /// Keychain is transiently locked).
    var hasStoredCredentials: Bool {
        credentialState == .present || credentialState == .readFailed
    }

    @ObservationIgnored private let credentialStore: ClinikoCredentialStore
    @ObservationIgnored private let authProbe: ClinikoAuthProbe
    @ObservationIgnored private var isApplyingExternalUpdate: Bool = false

    init(
        credentialStore: ClinikoCredentialStore = ClinikoCredentialStore(),
        authProbe: ClinikoAuthProbe = ClinikoAuthProbe()
    ) {
        self.credentialStore = credentialStore
        self.authProbe = authProbe
    }

    /// Refresh `credentialState` + `selectedShard` from the persisted store.
    /// Called from `.task { … }` on the section view.
    func refreshState() async {
        let shard = credentialStore.loadShard()
        applyExternalUpdate { self.selectedShard = shard }

        do {
            let present = try await credentialStore.hasAPIKey()
            credentialState = present ? .present : .absent
            // After a refresh we don't yet know if the stored key still
            // works — a verification probe runs only on user action.
            if present {
                if verificationStatus == .absent || verificationStatus == .readError {
                    verificationStatus = .unverified
                }
            } else {
                verificationStatus = .absent
            }
        } catch {
            // Keychain read failed (locked session, signing regression, etc.).
            // We deliberately do NOT flip `credentialState` to `.absent`: that
            // would silently disable Clinical Notes Mode for any consumer
            // gating on `hasStoredCredentials`.
            credentialState = .readFailed
            verificationStatus = .readError
            connectionStatus = .failure
            statusMessage = "Could not read stored credentials. Try removing and re-adding your API key."
        }
    }

    /// Persist the API key + shard, then probe `/users/me` to confirm the key
    /// works. The probe failure does not roll back the save — operators
    /// frequently rotate keys while offline.
    func saveAndTest() async {
        let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            connectionStatus = .failure
            statusMessage = "Paste an API key before saving."
            return
        }

        isBusy = true
        connectionStatus = .testing
        statusMessage = "Saving credentials and contacting Cliniko…"
        defer { isBusy = false }

        do {
            try await credentialStore.saveCredentials(apiKey: trimmed, shard: selectedShard)
        } catch ClinikoCredentialStore.Failure.missingAPIKey {
            connectionStatus = .failure
            statusMessage = "Paste an API key before saving."
            return
        } catch {
            connectionStatus = .failure
            statusMessage = "Could not save the API key to Keychain."
            return
        }

        // Save succeeded — clear the draft regardless of probe outcome so the
        // secret stops living in VM memory.
        apiKeyDraft = ""
        credentialState = .present
        // The card stays "unverified" until the probe succeeds; runProbe
        // promotes it to `.verified` on 2xx.
        verificationStatus = .unverified

        await runProbe()
    }

    /// Run `/users/me` against the currently stored credentials. Used by the
    /// "Test connection" button when credentials are already saved.
    func testConnection() async {
        guard hasStoredCredentials else {
            connectionStatus = .failure
            statusMessage = "No credentials saved yet."
            return
        }
        isBusy = true
        connectionStatus = .testing
        statusMessage = "Contacting Cliniko…"
        defer { isBusy = false }

        await runProbe()
    }

    /// Delete the API key + shard from disk and reset the UI back to a clean
    /// empty state. AC item 4 ("removing credentials disables Clinical Notes
    /// Mode toggle") will be enforced by #11 once that toggle ships — it can
    /// gate on `hasStoredCredentials` exposed here.
    func removeCredentials() async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await credentialStore.deleteCredentials()
        } catch {
            // Keychain delete failed but `deleteCredentials` clears the
            // shard `defer`-style; the API key is likely still on this Mac.
            connectionStatus = .failure
            statusMessage = "Could not remove credentials. Your API key may still be stored — open Keychain Access to clear it manually."
            return
        }
        applyExternalUpdate {
            self.selectedShard = .default
            self.apiKeyDraft = ""
        }
        credentialState = .absent
        verificationStatus = .absent
        connectionStatus = .idle
        statusMessage = "Cliniko credentials removed."
    }

    // MARK: - Status card derivation

    /// Display info for the connection status card. Pure function of state —
    /// makes the card test-friendly without exposing colours / icons in the
    /// VM API.
    struct StatusCardDisplay: Equatable {
        let icon: String
        let tint: Color
        let title: String
        let subtitle: String
    }

    var statusCardDisplay: StatusCardDisplay {
        switch verificationStatus {
        case .absent:
            return StatusCardDisplay(
                icon: "lock.shield",
                tint: Color.warmAmber,
                title: "No Cliniko credentials",
                subtitle: "Add your Cliniko API key below to enable clinical-notes export."
            )
        case .unverified:
            return StatusCardDisplay(
                icon: "exclamationmark.shield",
                tint: Color.warmAmber,
                title: "Saved but not yet verified",
                subtitle: "Your API key is stored on this Mac. Use Test connection to verify it against \(selectedShard.displayName)."
            )
        case .verified:
            return StatusCardDisplay(
                icon: "checkmark.shield.fill",
                tint: Color.successGreen,
                title: "Connected to Cliniko",
                subtitle: "Verified against \(selectedShard.displayName). Your API key is stored on this Mac only."
            )
        case .readError:
            return StatusCardDisplay(
                icon: "exclamationmark.triangle.fill",
                tint: Color.red,
                title: "Could not read stored credentials",
                subtitle: "macOS Keychain returned an error. Removing and re-adding your API key usually resolves this."
            )
        }
    }

    // MARK: - Private

    private func runProbe() async {
        let credentials: ClinikoCredentials?
        do {
            credentials = try await credentialStore.loadCredentials()
        } catch {
            credentialState = .readFailed
            verificationStatus = .readError
            connectionStatus = .failure
            statusMessage = "Could not read the saved API key."
            return
        }
        guard let credentials else {
            credentialState = .absent
            verificationStatus = .absent
            connectionStatus = .failure
            statusMessage = "No credentials saved."
            return
        }

        do {
            try await authProbe.ping(credentials: credentials)
            verificationStatus = .verified
            connectionStatus = .success
            statusMessage = "Connected to Cliniko (\(credentials.shard.displayName))."
        } catch ClinikoAuthProbeError.unauthorized {
            verificationStatus = .unverified
            connectionStatus = .failure
            statusMessage = "Cliniko rejected the API key. Double-check the key and the selected region."
        } catch ClinikoAuthProbeError.http(let status) {
            verificationStatus = .unverified
            connectionStatus = .failure
            statusMessage = "Cliniko responded with HTTP \(status). Try again, or contact Cliniko support."
        } catch ClinikoAuthProbeError.transport(let code) {
            verificationStatus = .unverified
            connectionStatus = .failure
            statusMessage = transportFailureMessage(for: code)
        } catch ClinikoAuthProbeError.cancelled {
            // User navigated away or session was invalidated. Don't render
            // a misleading "could not reach Cliniko" message.
            verificationStatus = .unverified
            connectionStatus = .idle
            statusMessage = nil
        } catch ClinikoAuthProbeError.nonHTTPResponse {
            verificationStatus = .unverified
            connectionStatus = .failure
            statusMessage = "Cliniko returned an unexpected response. Try again."
        } catch {
            // Catches `.unknown(typeName:)` and any unexpected throw type
            // with the same message — splitting them adds no UX value while
            // duplicating the branch arm.
            verificationStatus = .unverified
            connectionStatus = .failure
            statusMessage = "Unexpected error contacting Cliniko."
        }
    }

    private func transportFailureMessage(for code: URLError.Code) -> String {
        switch code {
        case .cannotFindHost, .dnsLookupFailed:
            return "Could not reach api.\(selectedShard.rawValue).cliniko.com — is the region correct?"
        case .notConnectedToInternet, .networkConnectionLost:
            return "You appear to be offline. Reconnect and try again."
        case .timedOut:
            return "The request to Cliniko timed out. Try again."
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid:
            return "Cliniko's TLS certificate could not be verified."
        default:
            return "Could not reach Cliniko — check your internet connection and try again."
        }
    }

    /// Wrap a property update so the `selectedShard.didSet` knows not to
    /// echo the change back to the credential store — used during refresh
    /// and remove flows.
    private func applyExternalUpdate(_ apply: () -> Void) {
        isApplyingExternalUpdate = true
        apply()
        isApplyingExternalUpdate = false
    }
}

// MARK: - Previews

#Preview("Clinical Notes Section") {
    ClinicalNotesSection(
        viewModel: ClinicalNotesSectionViewModel(),
        settingsService: SettingsService()
    )
    .frame(width: 640, height: 700)
}
