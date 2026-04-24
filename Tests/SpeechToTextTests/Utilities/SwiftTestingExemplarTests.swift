import Testing
import Foundation

// MARK: - Reference: Swift Testing patterns for this project
//
// This file exists as a reference implementation for contributors adding
// new tests using Swift Testing (`@Test` / `@Suite` / `#expect`). It
// exercises trivially-simple Foundation behaviour; the point is the
// *shape* of the tests, not the coverage.
//
// Guidance (see `.claude/CLAUDE.md` → "Operating rules" #2):
//   - NEW pure-logic and async tests → use Swift Testing (this file's style).
//   - UI / ViewInspector / XCUITest → keep using XCTest.
//   - Tag every Swift Testing test with at least one of .fast / .slow /
//     .requiresHardware (see `TestTags.swift`). CI filters on these.

// ---------------------------------------------------------------------------
// Pattern 1: a simple tagged test.
// ---------------------------------------------------------------------------

@Test("UUIDs produced in quick succession are distinct", .tags(.fast))
func uuids_areUnique_acrossCalls() {
    let a = UUID()
    let b = UUID()
    #expect(a != b)
}

// ---------------------------------------------------------------------------
// Pattern 2: parameterized test.
//
// Swift Testing's `arguments:` avoids the XCTest convention of per-case
// helper methods. One `@Test`, many inputs, clean reporting.
// ---------------------------------------------------------------------------

@Test(
    "Trimming known-whitespace strings yields the expected result",
    .tags(.fast),
    arguments: [
        ("  hello  ", "hello"),
        ("\thello\n", "hello"),
        ("hello", "hello"),
        ("   ", "")
    ]
)
func whitespaceTrim(input: String, expected: String) {
    #expect(input.trimmingCharacters(in: .whitespacesAndNewlines) == expected)
}

// ---------------------------------------------------------------------------
// Pattern 3: a `@Suite` that propagates a tag to every test it contains.
//
// Use for groups of related assertions. Tags on the suite apply to every
// member `@Test` unless the test carries its own explicit tag.
// ---------------------------------------------------------------------------

@Suite("Calendar date arithmetic", .tags(.fast))
struct DateArithmeticTests {
    @Test("Adding zero days preserves the date")
    func addingZeroDays_isIdentity() throws {
        let now = Date()
        let later = try #require(
            Calendar(identifier: .gregorian).date(byAdding: .day, value: 0, to: now)
        )
        #expect(now == later)
    }

    @Test("Adding 1 day advances the date")
    func addingOneDay_advances() throws {
        let now = Date()
        let later = try #require(
            Calendar(identifier: .gregorian).date(byAdding: .day, value: 1, to: now)
        )
        #expect(later > now)
    }
}
