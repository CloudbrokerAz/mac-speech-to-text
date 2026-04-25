import Foundation
import Testing
@testable import SpeechToText

@Suite("ClinikoShard", .tags(.fast))
struct ClinikoShardTests {

    @Test("apiHost composes from rawValue")
    func apiHostMatchesRawValue() {
        for shard in ClinikoShard.allCases {
            #expect(shard.apiHost == "api.\(shard.rawValue).cliniko.com")
        }
    }

    @Test("apiHost contains only ASCII lowercase hostname characters")
    func apiHostIsURLSafe() {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
        for shard in ClinikoShard.allCases {
            let scalars = shard.apiHost.unicodeScalars
            for scalar in scalars {
                #expect(allowed.contains(scalar), "shard \(shard.rawValue) host has unexpected character \(scalar)")
            }
        }
    }

    @Test("default is au1")
    func defaultIsAU1() {
        #expect(ClinikoShard.default == .au1)
    }

    @Test("displayName is non-empty for every case")
    func displayNamesPresent() {
        for shard in ClinikoShard.allCases {
            #expect(!shard.displayName.isEmpty)
            #expect(shard.displayName.contains(shard.rawValue))
        }
    }

    @Test("rawValue round-trips via Codable")
    func codableRoundTrip() throws {
        for shard in ClinikoShard.allCases {
            let encoded = try JSONEncoder().encode(shard)
            let decoded = try JSONDecoder().decode(ClinikoShard.self, from: encoded)
            #expect(decoded == shard)
        }
    }

    @Test("Identifiable id matches rawValue")
    func identifiableIdMatchesRawValue() {
        for shard in ClinikoShard.allCases {
            #expect(shard.id == shard.rawValue)
        }
    }

    @Test("all expected regions covered")
    func expectedRegionsCovered() {
        let raw = Set(ClinikoShard.allCases.map(\.rawValue))
        for expected in ["au1", "au2", "au3", "au4", "uk1", "uk2", "ca1", "us1", "eu1"] {
            #expect(raw.contains(expected), "missing shard \(expected)")
        }
    }
}
