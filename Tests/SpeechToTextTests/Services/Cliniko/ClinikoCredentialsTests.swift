import Foundation
import Testing
@testable import SpeechToText

@Suite("ClinikoCredentials", .tags(.fast))
struct ClinikoCredentialsTests {

    @Test("baseURL matches `https://api.{shard}.cliniko.com/v1/`")
    func baseURLPerShard() throws {
        for shard in ClinikoShard.allCases {
            let creds = try ClinikoCredentials(apiKey: "MS-fake-\(shard.rawValue)", shard: shard)
            #expect(creds.baseURL.absoluteString == "https://api.\(shard.rawValue).cliniko.com/v1/")
        }
    }

    @Test("baseURL is HTTPS only")
    func baseURLIsHTTPS() throws {
        let creds = try ClinikoCredentials(apiKey: "k", shard: .au1)
        #expect(creds.baseURL.scheme == "https")
    }

    @Test("basicAuthHeaderValue base64-encodes `apiKey:`")
    func basicAuthHeaderShape() throws {
        let creds = try ClinikoCredentials(apiKey: "MS-secret-au1", shard: .au1)
        let header = creds.basicAuthHeaderValue
        #expect(header.hasPrefix("Basic "))
        let encoded = String(header.dropFirst("Basic ".count))
        let data = Data(base64Encoded: encoded)
        #expect(data != nil)
        if let data {
            let decoded = String(data: data, encoding: .utf8)
            #expect(decoded == "MS-secret-au1:", "Cliniko Basic auth uses key as username + empty password")
        }
    }

    @Test("description redacts the API key")
    func descriptionDoesNotEchoKey() throws {
        let creds = try ClinikoCredentials(apiKey: "MS-super-secret-VALUE-123", shard: .uk1)
        let text = "\(creds)"
        #expect(!text.contains("MS-super-secret"))
        #expect(text.contains("<redacted>"))
        #expect(text.contains("uk1"))
    }

    @Test("Equatable distinguishes by key + shard")
    func equatable() throws {
        let a = try ClinikoCredentials(apiKey: "k1", shard: .au1)
        let b = try ClinikoCredentials(apiKey: "k1", shard: .au1)
        let c = try ClinikoCredentials(apiKey: "k1", shard: .au2)
        let d = try ClinikoCredentials(apiKey: "k2", shard: .au1)
        #expect(a == b)
        #expect(a != c)
        #expect(a != d)
    }

    @Test("baseURL composes against `user` endpoint")
    func appendingUser() throws {
        let creds = try ClinikoCredentials(apiKey: "k", shard: .au1)
        let url = creds.baseURL.appendingPathComponent("user")
        #expect(url.absoluteString == "https://api.au1.cliniko.com/v1/user")
    }

    @Test("base64 of the auth value uses standard alphabet")
    func base64StandardAlphabet() throws {
        // A handful of edge-case keys (multiples of 3 bytes, padding cases).
        for raw in ["a", "ab", "abc", "abcd", "abcde", "abcdef"] {
            let creds = try ClinikoCredentials(apiKey: raw, shard: .au1)
            let value = creds.basicAuthHeaderValue
            let encoded = String(value.dropFirst("Basic ".count))
            // Standard base64 alphabet: [A-Za-z0-9+/=]
            let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
            for scalar in encoded.unicodeScalars {
                #expect(allowed.contains(scalar), "non-standard base64 char in \(encoded)")
            }
        }
    }

    @Test("init rejects empty API key")
    func initRejectsEmptyKey() {
        #expect(throws: ClinikoCredentials.CredentialsError.emptyAPIKey) {
            _ = try ClinikoCredentials(apiKey: "", shard: .au1)
        }
    }

    @Test("init rejects whitespace-only API key")
    func initRejectsWhitespaceKey() {
        #expect(throws: ClinikoCredentials.CredentialsError.emptyAPIKey) {
            _ = try ClinikoCredentials(apiKey: "   \n\t  ", shard: .au1)
        }
    }

    @Test("init trims surrounding whitespace")
    func initTrimsWhitespace() throws {
        let creds = try ClinikoCredentials(apiKey: "  MS-trim-au1  \n", shard: .au1)
        // Verify via the basic-auth path — the `apiKey` field itself is internal.
        let encoded = String(creds.basicAuthHeaderValue.dropFirst("Basic ".count))
        let decoded = String(data: Data(base64Encoded: encoded) ?? Data(), encoding: .utf8) ?? ""
        #expect(decoded == "MS-trim-au1:")
    }

    @Test("baseURL is non-nil for every shard")
    func baseURLPerShardNonNil() throws {
        // Pins the `preconditionFailure` defence in `baseURL` — if a future
        // shard rawValue ever produces a malformed URL, this test fires
        // before runtime.
        for shard in ClinikoShard.allCases {
            let creds = try ClinikoCredentials(apiKey: "k", shard: shard)
            #expect(!creds.baseURL.absoluteString.isEmpty)
        }
    }
}
