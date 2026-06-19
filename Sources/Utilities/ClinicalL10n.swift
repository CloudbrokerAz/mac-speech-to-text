import Foundation

/// Incremental clinical-surface localization keys (ARC-12). Add entries to
/// `Resources/Localizable.xcstrings` and reference them here so call sites
/// stay typed and grep-friendly.
enum ClinicalL10n {
    static let reviewTitle = String(
        localized: "clinical.review.title",
        defaultValue: "Clinical Notes Review",
        bundle: .module,
        comment: "Review screen navigation title"
    )
    static let reviewGenerating = String(
        localized: "clinical.review.generating",
        defaultValue: "Generating clinical note",
        bundle: .module,
        comment: "VoiceOver label while LLM draft is pending"
    )
    static let patientPickerTitle = String(
        localized: "clinical.picker.patientTitle",
        defaultValue: "Patient",
        bundle: .module,
        comment: "Patient picker left-pane heading"
    )
    static let patientSearchPlaceholder = String(
        localized: "clinical.picker.searchPlaceholder",
        defaultValue: "Search by name",
        bundle: .module,
        comment: "Patient search field placeholder"
    )
    static let exportConfirmTitle = String(
        localized: "clinical.export.confirmTitle",
        defaultValue: "Confirm export",
        bundle: .module,
        comment: "Export flow confirmation step title"
    )
    static let onboardingTitle = String(
        localized: "clinical.onboarding.title",
        defaultValue: "Set up Clinical Notes",
        bundle: .module,
        comment: "Home tab onboarding stub heading"
    )
    static let onboardingSubtitle = String(
        localized: "clinical.onboarding.subtitle",
        defaultValue: "Complete these steps to start generating SOAP notes on-device.",
        bundle: .module,
        comment: "Home tab onboarding stub description"
    )
}
