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

        let keys = await store.keys()
        XCTAssertEqual(keys, ["alpha", "bravo"])

        let alpha = try await store.get(forKey: "alpha")
        XCTAssertEqual(alpha, Data("A".utf8))
    }
}
