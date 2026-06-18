// ClinikoUserAgentTests.swift
// macOS Local Speech-to-Text Application
//
// Table-driven coverage for `ClinikoUserAgent` (#253 / TST-5). Pins
// the configured email form, the no-email fallback, and whitespace
// normalisation — every outgoing Cliniko request carries this header.

import Foundation
import Testing
@testable import SpeechToText

@Suite("ClinikoUserAgent", .tags(.fast))
struct ClinikoUserAgentTests {

    struct MakeCase: Sendable {
        let contactEmail: String?
        let expected: String?
        let mustContain: String?
        let mustNotContain: String?

        init(
            contactEmail: String?,
            expected: String? = nil,
            mustContain: String? = nil,
            mustNotContain: String? = nil
        ) {
            self.contactEmail = contactEmail
            self.expected = expected
            self.mustContain = mustContain
            self.mustNotContain = mustNotContain
        }
    }

    private static let makeCases: [MakeCase] = [
        MakeCase(
            contactEmail: "doctor@example.test",
            expected: "mac-speech-to-text (doctor@example.test)"
        ),
        MakeCase(
            contactEmail: "  doctor@example.test  ",
            expected: "mac-speech-to-text (doctor@example.test)"
        ),
        MakeCase(
            contactEmail: nil,
            mustContain: "mac-speech-to-text/",
            mustNotContain: nil
        ),
        MakeCase(
            contactEmail: "   \t  ",
            mustContain: "github.com/CloudbrokerAz/mac-speech-to-text",
            mustNotContain: "mac-speech-to-text ()"
        )
    ]

    @Test(
        "make emits the configured or fallback User-Agent shape",
        .tags(.fast),
        arguments: makeCases
    )
    func make_contactEmailCases(makeCase: MakeCase) {
        let ua = ClinikoUserAgent.make(contactEmail: makeCase.contactEmail)

        if let expected = makeCase.expected {
            #expect(ua == expected)
        }
        if let mustContain = makeCase.mustContain {
            #expect(ua.contains(mustContain))
        }
        if let mustNotContain = makeCase.mustNotContain {
            #expect(!ua.contains(mustNotContain))
        }
        if makeCase.contactEmail == nil {
            #expect(ua.contains("github.com/CloudbrokerAz/mac-speech-to-text"))
        }
    }

    @Test("defaultProvider re-reads contact email from UserDefaults on each call")
    func defaultProvider_readsUserDefaultsLive() throws {
        let suiteName = "ClinikoUserAgentTests-\(UUID().uuidString)"
        let suite = try #require(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        let key = ClinikoCredentialStore.contactEmailUserDefaultsKey

        suite.set("first@example.test", forKey: key)
        let provider = ClinikoUserAgent.defaultProvider(userDefaults: suite)
        #expect(provider() == "mac-speech-to-text (first@example.test)")

        suite.set("second@example.test", forKey: key)
        #expect(provider() == "mac-speech-to-text (second@example.test)")

        suite.removeObject(forKey: key)
        #expect(provider().contains("github.com/CloudbrokerAz/mac-speech-to-text"))
    }
}
