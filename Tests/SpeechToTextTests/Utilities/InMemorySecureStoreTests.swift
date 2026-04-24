import XCTest
@testable import SpeechToText

/// Tests for `InMemorySecureStore`, the test-only `SecureStore` fake.
///
/// These tests also exercise the default protocol extension (`setString` /
/// `getString`), so they act as a contract-test for any future
/// `SecureStore` implementation.
final class InMemorySecureStoreTests: XCTestCase {

    // MARK: - Data API

    func test_getMissing_returnsNil() async throws {
        let store = InMemorySecureStore()
        let value = try await store.get(forKey: "missing")
        XCTAssertNil(value)
    }

    func test_setThenGet_returnsSameData() async throws {
        let store = InMemorySecureStore()
        let expected = Data("secret".utf8)
        try await store.set(expected, forKey: "api-key")
        let actual = try await store.get(forKey: "api-key")
        XCTAssertEqual(actual, expected)
    }

    func test_overwrite_replacesValue() async throws {
        let store = InMemorySecureStore()
        try await store.set(Data("old".utf8), forKey: "k")
        try await store.set(Data("new".utf8), forKey: "k")
        let actual = try await store.get(forKey: "k")
        XCTAssertEqual(actual, Data("new".utf8))
    }

    func test_delete_removesValue() async throws {
        let store = InMemorySecureStore()
        try await store.set(Data("x".utf8), forKey: "k")
        try await store.delete(forKey: "k")
        let actual = try await store.get(forKey: "k")
        XCTAssertNil(actual)
    }

    func test_deleteMissing_isNoOp() async throws {
        let store = InMemorySecureStore()
        try await store.delete(forKey: "never-existed")
        let count = await store.count()
        XCTAssertEqual(count, 0)
    }

    func test_deleteAll_clearsEveryItem() async throws {
        let store = InMemorySecureStore(initial: [
            "a": Data("1".utf8),
            "b": Data("2".utf8)
        ])

        let countBefore = await store.count()
        XCTAssertEqual(countBefore, 2)

        try await store.deleteAll()

        let countAfter = await store.count()
        XCTAssertEqual(countAfter, 0)
    }

    // MARK: - String convenience (default protocol extension)

    func test_setString_getString_roundTrip() async throws {
        let store = InMemorySecureStore()
        try await store.setString("hello", forKey: "greeting")
        let value = try await store.getString(forKey: "greeting")
        XCTAssertEqual(value, "hello")
    }

    func test_getString_missing_returnsNil() async throws {
        let store = InMemorySecureStore()
        let value = try await store.getString(forKey: "missing")
        XCTAssertNil(value)
    }

    // MARK: - Initial state

    func test_initial_state_isReflected() async throws {
        let initial: [String: Data] = [
            "alpha": Data("A".utf8),
            "bravo": Data("B".utf8)
        ]
        let store = InMemorySecureStore(initial: initial)

        // Assert via the public `get` API (not the `keys()` helper) so a
        // future divergence between internal state and the public contract
        // is caught.
        let alpha = try await store.get(forKey: "alpha")
        XCTAssertEqual(alpha, Data("A".utf8))

        let bravo = try await store.get(forKey: "bravo")
        XCTAssertEqual(bravo, Data("B".utf8))

        let missing = try await store.get(forKey: "charlie")
        XCTAssertNil(missing)
    }

    // MARK: - Byte-transparency

    func test_roundTrip_preservesBinaryContent() async throws {
        // Null bytes + non-UTF-8 bytes. Catches any future refactor that
        // silently routes through `String` and corrupts arbitrary-byte secrets.
        let store = InMemorySecureStore()
        let bytes: [UInt8] = [0x00, 0xFF, 0xFE, 0x00, 0xC3, 0x28, 0x00]
        let expected = Data(bytes)

        try await store.set(expected, forKey: "binary-blob")
        let actual = try await store.get(forKey: "binary-blob")

        XCTAssertEqual(actual, expected)
        XCTAssertEqual(actual?.count, expected.count)
    }

    // MARK: - Bulk delete edge

    func test_deleteAll_onEmptyStore_isNoOp() async throws {
        let store = InMemorySecureStore()
        try await store.deleteAll()
        let count = await store.count()
        XCTAssertEqual(count, 0)
    }

    // MARK: - Concurrency contract

    func test_concurrent_setsAndGets_doNotCorruptState() async throws {
        // Fires N concurrent writes and reads through the actor to lock in
        // the serialisation contract the type advertises. If the actor is
        // ever refactored to a class with a data-race bug, this test should
        // start failing under ThreadSanitizer.
        let store = InMemorySecureStore()
        let count = 128

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<count {
                group.addTask {
                    let key = "key-\(i)"
                    let value = Data("value-\(i)".utf8)
                    try? await store.set(value, forKey: key)
                    _ = try? await store.get(forKey: key)
                }
            }
        }

        let finalCount = await store.count()
        XCTAssertEqual(finalCount, count)

        for i in 0..<count {
            let value = try await store.get(forKey: "key-\(i)")
            XCTAssertEqual(value, Data("value-\(i)".utf8), "key-\(i) value mismatch")
        }
    }
}
