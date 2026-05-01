import Foundation
import Testing
@testable import SpeechToText

/// Unit tests for `OpaqueClinikoID` (issue #59). The newtype's whole
/// purpose is to:
/// 1. Refuse free-form strings at compile time at the `AuditRecord` /
///    `ClinicalSession` boundary.
/// 2. Encode/decode as a **bare** JSON string so the on-disk
///    `audit.jsonl` schema stays unchanged from the predecessor
///    `String`-typed fields.
/// 3. Round-trip the `Int ↔ String` boundary in one place.
///
/// (1) is enforced statically — a regression would surface as a build
/// failure, not a test failure. The negative compile-failure case is
/// documented as a comment block at the bottom of this suite. (2) and
/// (3) are pinned by the tests below.
@Suite("OpaqueClinikoID", .tags(.fast))
struct OpaqueClinikoIDTests {

    // MARK: - Construction

    @Test("init(_:Int) preserves the numeric value as the canonical string form")
    func intInit_preservesValue() {
        let id = OpaqueClinikoID(1001)
        #expect(id.rawValue == "1001")
    }

    @Test("init(_:String) preserves the string-shaped wire form (Patient.id, #127)")
    func stringInit_preservesValue() {
        // Cliniko's documented `Patient.id` shape is `string($int64)` —
        // post-#127 the picker speaks `String` at the SessionStore
        // boundary, and this canonical init is the path. Distinct from
        // `init(rawValue:)` so a contributor can tell production
        // type-tagging apart from Codable / test deterministic-literal
        // wiring.
        let id = OpaqueClinikoID("1001")
        #expect(id.rawValue == "1001")
    }

    @Test("init(_:Int) and init(_:String) with the same digit-string produce equal IDs")
    func intAndStringInit_producesEqualIDs() {
        // The Int and String boundaries store the same `rawValue` so a
        // patient picked by the new String-shaped boundary is equal to
        // one constructed from the legacy Int boundary — keeps existing
        // assertions of the `OpaqueClinikoID(<digit-int>) == ...` form
        // valid across the #127 migration.
        let viaInt = OpaqueClinikoID(42)
        let viaString = OpaqueClinikoID("42")
        #expect(viaInt == viaString)
        #expect(viaInt.hashValue == viaString.hashValue)
    }

    @Test("init(rawValue:) preserves the string verbatim")
    func rawValueInit_preservesString() {
        // `init(rawValue:)` is total over `String`. Production
        // callsites must not exercise it for non-numeric inputs — see
        // the type-level doc-comment — but the type itself does not
        // refuse them, so the test pins the round-trip property.
        let id = OpaqueClinikoID(rawValue: "patient-99")
        #expect(id.rawValue == "patient-99")
    }

    @Test("init(_:Int) and init(rawValue:) with the same digit-string produce equal IDs")
    func dualInit_producesEqualIDs() {
        let viaInt = OpaqueClinikoID(42)
        let viaString = OpaqueClinikoID(rawValue: "42")
        #expect(viaInt == viaString)
        #expect(viaInt.hashValue == viaString.hashValue)
    }

    // MARK: - Wire shape (the `audit.jsonl` schema invariant)

    @Test("Encodes as a bare JSON string, not as a wrapping object")
    func codable_encodesAsBareString() throws {
        let id = OpaqueClinikoID(1001)
        let encoded = try JSONEncoder().encode(id)
        let json = try #require(String(data: encoded, encoding: .utf8))

        // Critical: must be `"1001"`, NOT `{"rawValue":"1001"}`. The
        // pre-#59 audit ledger has bytes like
        // `"patient_id":"1001"` and the post-#59 decoder still reads
        // them — that's the `audit.jsonl` back-compat invariant the
        // issue body calls out.
        #expect(json == "\"1001\"")
    }

    @Test("Decodes a bare JSON string (audit-jsonl back-compat)")
    func codable_decodesBareString() throws {
        let json = try #require("\"42\"".data(using: .utf8))
        let id = try JSONDecoder().decode(OpaqueClinikoID.self, from: json)
        #expect(id.rawValue == "42")
    }

    @Test("Round-trips through Codable preserves rawValue exactly")
    func codable_roundTrip_preservesRawValue() throws {
        let original = OpaqueClinikoID(rawValue: "5678-edge")
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(OpaqueClinikoID.self, from: encoded)
        #expect(decoded == original)
        #expect(decoded.rawValue == "5678-edge")
    }

    @Test("Decodes inside a containing object with the field key")
    func codable_decodesInsideObject() throws {
        struct Wrapper: Codable, Equatable {
            let id: OpaqueClinikoID
        }
        // Mirrors the audit.jsonl shape — an object whose `id`-named
        // field is a bare string. Decoder must descend into the
        // containing key without expecting a wrapping object.
        let json = try #require(#"{"id":"9876543"}"#.data(using: .utf8))
        let wrapper = try JSONDecoder().decode(Wrapper.self, from: json)
        #expect(wrapper.id == OpaqueClinikoID(9876543))
    }

    @Test("Empty rawValue round-trips through Codable")
    func codable_emptyRawValue_roundTrips() throws {
        // Adversarial corner. The type does not refuse an empty
        // rawValue at construction; the wire-shape test pins that this
        // case round-trips as a bare empty JSON string (`""`) rather
        // than failing or transforming. No production path should ever
        // produce an empty ID, but if a tampered audit row carries one,
        // the decoder must not silently transform it into something
        // else (the read path is what surfaces the lie, not the
        // decoder).
        let original = OpaqueClinikoID(rawValue: "")
        let encoded = try JSONEncoder().encode(original)
        #expect(String(data: encoded, encoding: .utf8) == "\"\"")
        let decoded = try JSONDecoder().decode(OpaqueClinikoID.self, from: encoded)
        #expect(decoded == original)
    }

    @Test("Encodes inside a containing object as a bare-string field")
    func codable_encodesInsideObject() throws {
        struct Wrapper: Codable {
            let id: OpaqueClinikoID
        }
        let encoded = try JSONEncoder().encode(Wrapper(id: OpaqueClinikoID(123)))
        let parsed = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        let idValue = parsed?["id"]

        // `JSONSerialization` will surface a JSON string as a Swift
        // `String`; a wrapping `{"rawValue":"123"}` object would
        // surface as `[String: Any]`. Pinning the String case is what
        // proves the bare-string invariant downstream of #59.
        #expect((idValue as? String) == "123")
    }

    // MARK: - Hashable

    @Test("Hashable equality is rawValue-driven")
    func hashable_rawValueDriven() {
        let a = OpaqueClinikoID(1001)
        let b = OpaqueClinikoID(rawValue: "1001")
        let c = OpaqueClinikoID(rawValue: "1002")

        #expect(a == b)
        #expect(a != c)

        var set: Set<OpaqueClinikoID> = []
        set.insert(a)
        set.insert(b) // duplicate rawValue → not added
        set.insert(c)
        #expect(set.count == 2)
    }

    // MARK: - Reflection / no CustomStringConvertible
    //
    // The type deliberately does NOT conform to `CustomStringConvertible`
    // so that an accidental log site like `\(id)` falls back to Swift's
    // reflection-based form (`OpaqueClinikoID(rawValue: "1001")`) which
    // is obviously-PHI-shaped — the contributor reads the leak rather
    // than letting `1001` slip into the log under the appearance of an
    // innocuous integer. The PHI rule is documented on the type; this
    // is the redundancy that lets it actually hold.

    @Test("String(describing:) renders the reflection form, not a bare value")
    func reflection_showsTypeContext() {
        let id = OpaqueClinikoID(1001)
        let described = String(describing: id)
        // Belt-and-braces: assert the type name appears, not just the
        // bare digits. The exact format is Swift-runtime-dependent
        // (likely `OpaqueClinikoID(rawValue: "1001")`), so don't pin
        // the byte sequence — pin the property that matters.
        #expect(described.contains("OpaqueClinikoID"))
    }

    // MARK: - Type-system invariant
    //
    // Pinning the static refusal of free-form strings is the load-bearing
    // contract of #59. The check is structural (compile-time), not
    // runtime — Swift will reject these uses at build time:
    //
    //     // Won't compile — `AuditRecord.init(patientID:)` accepts only
    //     // `OpaqueClinikoID`, not `String`:
    //     // _ = AuditRecord(
    //     //     timestamp: Date(),
    //     //     patientID: "Mrs Smith",            // ❌ type error
    //     //     appointmentID: nil,
    //     //     noteID: "",                          // ❌ type error
    //     //     clinikoStatus: 201,
    //     //     appVersion: "0.0.0"
    //     // )
    //
    //     // Won't compile — `SessionStore.setSelectedPatient(id:)`
    //     // accepts only `OpaqueClinikoID?`:
    //     // sessionStore.setSelectedPatient(id: "totally-not-a-cliniko-id")  // ❌
    //
    // The positive direction — that `OpaqueClinikoID` IS accepted — is
    // exercised end-to-end by every other test in this suite. If a
    // future change widens any of the migrated `init`s back to `String`,
    // those callsites would silently re-enable the bug class #59 closes
    // and the audit ledger's PHI-leak guard becomes structural-only
    // (which is what the issue body warns against).
}
