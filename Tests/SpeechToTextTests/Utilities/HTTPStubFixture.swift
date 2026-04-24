import Foundation

/// Loads JSON + text fixture files shipped with the test bundle.
///
/// Fixtures live under `Tests/SpeechToTextTests/Fixtures/` and are copied into the test
/// bundle via `resources: [.copy("Fixtures")]` in `Package.swift`. Access is via
/// `Bundle.module` which SPM synthesises automatically once any resources are declared
/// on the target.
///
/// Path convention: use forward-slash segments relative to `Fixtures/`,
/// e.g. `cliniko/responses/users_me.json`.
enum HTTPStubFixture {
    enum FixtureError: Swift.Error, CustomStringConvertible, Equatable, Sendable {
        case notFound(path: String)
        case readFailed(path: String, underlying: Swift.Error)

        var description: String {
            switch self {
            case .notFound(let path):
                return "HTTPStubFixture: fixture not found at 'Fixtures/\(path)'"
            case .readFailed(let path, let underlying):
                return "HTTPStubFixture: read failed for 'Fixtures/\(path)': \(underlying)"
            }
        }

        // Ignore `underlying` in equality so `XCTAssertEqual`-style
        // assertions work across Foundation's various `NSError` instances
        // that represent the same failure.
        static func == (lhs: FixtureError, rhs: FixtureError) -> Bool {
            switch (lhs, rhs) {
            case let (.notFound(l), .notFound(r)):
                return l == r
            case let (.readFailed(l, _), .readFailed(r, _)):
                return l == r
            default:
                return false
            }
        }
    }

    /// Load a fixture's raw bytes.
    static func load(_ path: String) throws -> Data {
        // Reject ambiguous paths up-front. Trailing "/" otherwise resolves
        // to the directory itself, which Bundle happily returns a URL for
        // and `Data(contentsOf:)` then fails on with a confusing
        // "Is a directory" error. Empty paths have no filename to match.
        guard !path.isEmpty, !path.hasSuffix("/") else {
            throw FixtureError.notFound(path: path)
        }
        let components = path.split(separator: "/").map(String.init)
        guard let filename = components.last, !filename.isEmpty else {
            throw FixtureError.notFound(path: path)
        }
        let name = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        let subdirectory: String?
        if components.count > 1 {
            subdirectory = "Fixtures/" + components.dropLast().joined(separator: "/")
        } else {
            subdirectory = "Fixtures"
        }

        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: ext.isEmpty ? nil : ext,
            subdirectory: subdirectory
        ) else {
            throw FixtureError.notFound(path: path)
        }

        do {
            return try Data(contentsOf: url)
        } catch {
            throw FixtureError.readFailed(path: path, underlying: error)
        }
    }

    /// Load a fixture and decode it as `T`.
    static func loadJSON<T: Decodable>(
        _ type: T.Type,
        _ path: String,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> T {
        let data = try load(path)
        return try decoder.decode(type, from: data)
    }
}
