// AboutSection.swift
// macOS Local Speech-to-Text Application
//
// Part 2: Unified Main View - About Section
// Displays app info, version, keyboard shortcuts, and links

import SwiftUI

/// About section for the Main View sidebar
/// Displays app identity, keyboard shortcuts reference, and support links
struct AboutSection: View {
    // MARK: - Dependencies

    @Bindable var viewModel: AboutSectionViewModel

    /// Optional clinical-notes model status (#104). When non-nil and the
    /// app's Clinical Notes Mode pipeline is configured, the "Powered By"
    /// section renders a Gemma 4 badge with a live state pill. nil keeps
    /// the section Parakeet-only — used by previews and tests that don't
    /// stand up the full pipeline.
    let modelStatusViewModel: ClinicalNotesModelStatusViewModel?

    // MARK: - Environment

    @Environment(\.openURL) private var openURL

    // MARK: - Animation State

    @State private var isPulsing: Bool = false

    // MARK: - Init

    init(
        viewModel: AboutSectionViewModel,
        modelStatusViewModel: ClinicalNotesModelStatusViewModel? = nil
    ) {
        self.viewModel = viewModel
        self.modelStatusViewModel = modelStatusViewModel
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // App identity header
            appIdentitySection

            Divider()

            // Keyboard shortcuts
            keyboardShortcutsSection

            Divider()

            // Technology section
            technologySection

            Divider()

            // Links section
            linksSection

            Spacer()

            // Footer with copyright
            copyrightFooter
        }
        .padding(20)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("aboutSection")
    }

    // MARK: - Logo Loading

    /// Load app logo from various sources with fallback
    private static func loadAppLogo() -> NSImage {
        // Try main bundle Resources folder first (xcodebuild copies resources here)
        if let url = Bundle.main.url(forResource: "app_logov2", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }

        // Try xcassets
        if let image = NSImage(named: "AppLogo") {
            return image
        }

        // Fallback to app icon. In a unit-test context (no NSApplication
        // launched) `NSApp.applicationIconImage` is nil; return an empty
        // placeholder so view inspection doesn't crash. The production
        // path always has at least the system icon available.
        if let appIcon = NSApp?.applicationIconImage {
            return appIcon
        }
        return NSImage()
    }

    // MARK: - App Identity Section

    private var appIdentitySection: some View {
        VStack(spacing: 16) {
            // App logo with circular crop and animation (matching welcome screen)
            ZStack {
                // Animated outer pulse ring
                Circle()
                    .stroke(Color.amberPrimary.opacity(isPulsing ? 0.15 : 0.4), lineWidth: isPulsing ? 6 : 3)
                    .frame(width: isPulsing ? 108 : 100, height: isPulsing ? 108 : 100)
                    .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: isPulsing)

                // Outer glow ring
                Circle()
                    .stroke(Color.amberPrimary.opacity(0.4), lineWidth: 2)
                    .frame(width: 100, height: 100)

                // App logo - circular crop (with fallback to app icon)
                Image(nsImage: Self.loadAppLogo())
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 96, height: 96)
                    .clipShape(Circle())
            }
            .shadow(color: Color.amberPrimary.opacity(0.3), radius: 10, y: 3)
            .accessibilityHidden(true)
            .onAppear {
                isPulsing = true
            }

            VStack(spacing: 4) {
                // App name
                Text("Speech to Text")
                    .font(.title2)
                    .fontWeight(.semibold)

                // Version
                Text("Version \(viewModel.appVersion) (\(viewModel.buildNumber))")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Tagline
                Text("Local. Private. Fast.")
                    .font(.callout)
                    .fontWeight(.medium)
                    .foregroundStyle(Color.warmAmber)
                    .padding(.top, 4)

                // Description
                Text("Transform your voice into text instantly with on-device AI. No internet required, no data leaves your Mac. Just press a hotkey or say a wake word and start speaking.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
                    .padding(.horizontal, 8)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Speech to Text, Version \(viewModel.appVersion), Local Private Fast")
        .accessibilityIdentifier("aboutSection.identity")
    }

    // MARK: - Keyboard Shortcuts Section

    private var keyboardShortcutsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Keyboard Shortcuts")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)

            VStack(spacing: 8) {
                ForEach(viewModel.keyboardShortcuts, id: \.key) { shortcut in
                    KeyboardShortcutRow(shortcut: shortcut)
                        .accessibilityIdentifier("aboutSection.shortcut.\(shortcut.key)")
                }
            }
        }
        .accessibilityIdentifier("aboutSection.shortcuts")
    }

    // MARK: - Technology Section

    private static let gemmaByteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        return formatter
    }()

    /// Manifest size in human-readable form. Falls back to a generic phrase
    /// when the manifest is missing (`manifestSizeBytes == 0`) — keeps the
    /// subtitle copy from reading "Zero KB" mid-sentence.
    private func formattedGemmaSize(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "~5 GB" }
        return Self.gemmaByteFormatter.string(fromByteCount: bytes)
    }

    /// Maps the live `LLMDownloadState` to the badge's pill copy + tint.
    /// PHI-free — only structural state.
    private func pillForGemmaState(
        _ state: LLMDownloadState,
        progress: Double
    ) -> PoweredByBadge.StatePill {
        switch state {
        case .idle:
            return PoweredByBadge.StatePill(label: "Not downloaded", tint: Color.warmAmber)
        case .downloading:
            let clamped = min(max(progress, 0), 1)
            let pct = Int((clamped * 100).rounded())
            return PoweredByBadge.StatePill(label: "Downloading \(pct)%", tint: Color.warmAmber)
        case .verified:
            return PoweredByBadge.StatePill(label: "Verifying", tint: Color.warmAmber)
        case .ready:
            return PoweredByBadge.StatePill(label: "Ready", tint: Color.successGreen)
        case .failed:
            return PoweredByBadge.StatePill(label: "Failed", tint: Color.errorRed)
        case .cancelled:
            return PoweredByBadge.StatePill(label: "Cancelled", tint: Color.secondary)
        }
    }

    private var technologySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Powered By")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 8) {
                // Parakeet — always shown, no state pill (always-on).
                PoweredByBadge(
                    icon: "waveform.badge.mic",
                    iconColor: Color.amberPrimary,
                    name: "NVIDIA Parakeet TDT",
                    versionTag: "0.6b-v3",
                    subtitle: "State-of-the-art multilingual speech recognition running locally via Apple Neural Engine",
                    accentColor: Color.amberPrimary,
                    statePill: nil
                )

                // Gemma 4 — only when the VM is available (Clinical Notes
                // Mode pipeline is configured). The state pill reflects
                // the live download lifecycle. PHI-free by construction
                // (#104 / `.claude/references/phi-handling.md`).
                if let modelStatusViewModel {
                    let sizeText = formattedGemmaSize(modelStatusViewModel.manifestSizeBytes)
                    PoweredByBadge(
                        icon: "brain.head.profile",
                        iconColor: Color.amberPrimary,
                        name: "Gemma 4 E4B-IT",
                        versionTag: "mlx-4bit",
                        subtitle: "Local clinical-note drafting via MLX Swift on Apple Silicon. \(sizeText). PHI never leaves your Mac.",
                        accentColor: Color.amberPrimary,
                        statePill: pillForGemmaState(
                            modelStatusViewModel.state,
                            progress: modelStatusViewModel.progress
                        )
                    )
                }

                // Privacy note
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield.fill")
                        .font(.caption)
                        .foregroundStyle(Color.successGreen)

                    Text("All processing happens on-device. Your voice never leaves your Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
            }
        }
        .accessibilityIdentifier("aboutSection.technology")
    }

    // MARK: - Links Section

    private var linksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Help & Support")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)

            // Acknowledgments button (full width)
            Button {
                viewModel.openAcknowledgments()
            } label: {
                HStack {
                    Image(systemName: "heart")
                        .font(.caption)

                    Text("Acknowledgments")
                        .font(.callout)

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("aboutSection.acknowledgementsLink")
        }
        .accessibilityIdentifier("aboutSection.links")
    }

    // MARK: - Copyright Footer

    private var copyrightFooter: some View {
        VStack(spacing: 8) {
            Divider()

            Text(viewModel.copyrightText)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)

            Text("Made with care for your privacy")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .italic()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(viewModel.copyrightText)
        .accessibilityIdentifier("aboutSection.copyright")
    }
}

// MARK: - Keyboard Shortcut Row

private struct KeyboardShortcutRow: View {
    let shortcut: KeyboardShortcutInfo

    var body: some View {
        HStack(spacing: 12) {
            // Key combination
            Text(shortcut.keyCombo)
                .font(.system(.callout, design: .monospaced))
                .fontWeight(.medium)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 4))

            // Description
            Text(shortcut.description)
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(shortcut.keyCombo): \(shortcut.description)")
    }
}

// MARK: - Link Button

private struct LinkButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(Color.warmAmber)

                Text(title)
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.warmAmber.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint("Opens in browser")
    }
}

// MARK: - Keyboard Shortcut Info

struct KeyboardShortcutInfo: Identifiable {
    let id = UUID()
    let key: String
    let keyCombo: String
    let description: String
}

// MARK: - About Section ViewModel

@Observable
@MainActor
final class AboutSectionViewModel {
    // MARK: - App Info

    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    var copyrightText: String {
        let year = Calendar.current.component(.year, from: Date())
        return "\u{00A9} \(year) Speech to Text"
    }

    // MARK: - Keyboard Shortcuts

    let keyboardShortcuts: [KeyboardShortcutInfo] = [
        KeyboardShortcutInfo(
            key: "record",
            keyCombo: "\u{2303}\u{21E7}Space",
            description: "Hold to record"
        ),
        KeyboardShortcutInfo(
            key: "settings",
            keyCombo: "\u{2318},",
            description: "Open settings"
        ),
        KeyboardShortcutInfo(
            key: "quit",
            keyCombo: "\u{2318}Q",
            description: "Quit"
        )
    ]

    // MARK: - URLs

    private static let supportURLString = "https://speechtotext.app/support"
    private static let privacyPolicyURLString = "https://speechtotext.app/privacy"
    private static let acknowledgementsURLString = "https://claude.ai"

    // MARK: - Initialization

    init() {}

    // MARK: - Methods

    func openSupport(openURL: OpenURLAction) {
        guard let url = URL(string: Self.supportURLString) else {
            AppLogger.system.error("Invalid support URL: \(Self.supportURLString)")
            return
        }
        openURL(url) { success in
            if !success {
                AppLogger.system.error("Failed to open support URL")
            }
        }
    }

    func openPrivacyPolicy(openURL: OpenURLAction) {
        guard let url = URL(string: Self.privacyPolicyURLString) else {
            AppLogger.system.error("Invalid privacy policy URL: \(Self.privacyPolicyURLString)")
            return
        }
        openURL(url) { success in
            if !success {
                AppLogger.system.error("Failed to open privacy policy URL")
            }
        }
    }

    func openAcknowledgments() {
        guard let url = URL(string: Self.acknowledgementsURLString) else {
            AppLogger.system.error("Invalid acknowledgements URL: \(Self.acknowledgementsURLString)")
            return
        }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Powered By Badge

/// Reusable "Powered By" technology card. Used twice in `AboutSection`:
/// once for Parakeet (always shown, no state pill) and once for Gemma 4
/// (shown when Clinical Notes Mode infrastructure is available; renders a
/// real download-state pill driven by `ClinicalNotesModelStatusViewModel`).
///
/// PHI-free by construction — every input is structural metadata
/// (model name, version tag, byte size). See
/// `.claude/references/phi-handling.md`.
private struct PoweredByBadge: View {
    /// Pill rendered next to the version tag. `nil` hides the pill
    /// entirely (used by Parakeet, which is always-on).
    struct StatePill: Equatable {
        let label: String
        let tint: Color
    }

    let icon: String
    let iconColor: Color
    let name: String
    let versionTag: String
    let subtitle: String
    let accentColor: Color
    let statePill: StatePill?

    private var slug: String { aboutSectionSlugify(name) }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(iconColor)
                .frame(width: 32)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.callout)
                        .fontWeight(.medium)

                    Text(versionTag)
                        .font(.caption)
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(accentColor.opacity(0.2))
                        .foregroundStyle(accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 4))

                    if let pill = statePill {
                        Text(pill.label)
                            .font(.caption)
                            .fontWeight(.medium)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(pill.tint.opacity(0.2))
                            .foregroundStyle(pill.tint)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .accessibilityIdentifier("aboutSection.poweredByBadge.\(slug).statePill")
                    }
                }

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("aboutSection.poweredByBadge.\(slug)")
    }
}

/// Lower-cases an arbitrary display name and converts non-alphanumeric
/// runs to single hyphens for use as an accessibility-identifier suffix.
/// Pure / Sendable / file-scope — no Foundation dependency beyond
/// `String`. Lives at file scope so previews + the badge can share it.
private func aboutSectionSlugify(_ value: String) -> String {
    var result = ""
    var lastWasHyphen = true   // so leading non-alphanumerics drop, not produce "-foo"
    for scalar in value.unicodeScalars {
        if scalar.isASCII, let ascii = Character(scalar).lowercased().first,
           ascii.isLetter || ascii.isNumber {
            result.append(ascii)
            lastWasHyphen = false
        } else if !lastWasHyphen {
            result.append("-")
            lastWasHyphen = true
        }
    }
    if result.hasSuffix("-") { result.removeLast() }
    return result
}

// MARK: - Previews

#Preview("About Section") {
    AboutSection(viewModel: AboutSectionViewModel())
        .frame(width: 320, height: 600)
        .padding()
}

#Preview("About Section - Dark Mode") {
    AboutSection(viewModel: AboutSectionViewModel())
        .frame(width: 320, height: 600)
        .padding()
        .preferredColorScheme(.dark)
}

#Preview("About Section - With Gemma 4 Ready") {
    // Real Gemma 4 manifest size — keeps the subtitle copy realistic.
    let modelStatusVM = ClinicalNotesModelStatusViewModel(
        state: .ready,
        progress: 1,
        manifestSizeBytes: 5_249_808_308,
        modelDirectoryURL: URL(
            fileURLWithPath: "/Users/example/Library/Application Support/com.speechtotext.app/Models/gemma-4-e4b-it-4bit"
        )
    )
    return AboutSection(
        viewModel: AboutSectionViewModel(),
        modelStatusViewModel: modelStatusVM
    )
        .frame(width: 320, height: 700)
        .padding()
}
