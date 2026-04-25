import Foundation
import Testing
@testable import SpeechToText

/// Coverage for the `clinicalNotesModeEnabled` flag added in #11. The flag
/// lives on `GeneralConfiguration` and is persisted as part of the JSON
/// `UserSettings` blob in `UserDefaults`. Two contracts:
///
/// 1. **Default false.** Existing builds upgrading to a flag-aware build must
///    see the recording flow unchanged until they explicitly opt in.
/// 2. **Decode migration.** A `UserSettings` blob saved by a pre-#11 build
///    (no `clinicalNotesModeEnabled` key) must decode cleanly with the flag
///    defaulting to `false` — `decodeIfPresent` handles this; the test pins
///    the contract so a future refactor doesn't accidentally make the field
///    required.
@Suite("UserSettings: Clinical Notes Mode flag (#11)", .tags(.fast))
struct ClinicalNotesModeSettingsTests {

    @Test("Default value is false")
    func defaultValue_isFalse() {
        let general = UserSettings.default.general
        #expect(general.clinicalNotesModeEnabled == false)
    }

    @Test("Memberwise init defaults clinicalNotesModeEnabled to false")
    func memberwiseInit_defaultsToFalse() {
        let general = GeneralConfiguration()
        #expect(general.clinicalNotesModeEnabled == false)
    }

    @Test("Memberwise init honours explicit true")
    func memberwiseInit_acceptsExplicitTrue() {
        let general = GeneralConfiguration(clinicalNotesModeEnabled: true)
        #expect(general.clinicalNotesModeEnabled == true)
    }

    @Test("Decoding pre-#11 settings JSON defaults the flag to false")
    func decode_legacyJSON_defaultsFlagToFalse() throws {
        // Synthetic pre-#11 payload — every persisted GeneralConfiguration
        // field present except `clinicalNotesModeEnabled`. `decodeIfPresent`
        // must fill it in.
        let legacyJSON = #"""
        {
            "launchAtLogin": false,
            "autoInsertText": true,
            "copyToClipboard": true,
            "accessibilityPromptDismissed": false,
            "clipboardOnlyMode": false,
            "pasteBehavior": "paste"
        }
        """#

        let data = try #require(legacyJSON.data(using: .utf8))
        let decoded = try JSONDecoder().decode(GeneralConfiguration.self, from: data)
        #expect(decoded.clinicalNotesModeEnabled == false)
    }

    @Test("Round-tripping the flag preserves it")
    func encodeDecode_preservesFlag() throws {
        let original = GeneralConfiguration(clinicalNotesModeEnabled: true)

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let roundTripped = try decoder.decode(GeneralConfiguration.self, from: data)

        #expect(roundTripped.clinicalNotesModeEnabled == true)
    }

    @Test("Pre-#11 JSON containing a missing pasteBehavior also fills the new flag")
    func decode_legacyJSON_withoutPasteBehavior_defaultsBothFields() throws {
        // Even older payload predating #11 *and* the pasteBehavior addition.
        // Both `decodeIfPresent` paths must hold simultaneously.
        let legacyJSON = #"""
        {
            "launchAtLogin": true,
            "autoInsertText": false,
            "copyToClipboard": false,
            "accessibilityPromptDismissed": true,
            "clipboardOnlyMode": true
        }
        """#

        let data = try #require(legacyJSON.data(using: .utf8))
        let decoded = try JSONDecoder().decode(GeneralConfiguration.self, from: data)
        #expect(decoded.pasteBehavior == .pasteOnly)
        #expect(decoded.clinicalNotesModeEnabled == false)
    }
}
