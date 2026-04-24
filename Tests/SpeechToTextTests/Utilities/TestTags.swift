import Testing

/// Shared tags used across Swift Testing test files in this target.
///
/// Use these to route tests into the right CI layer (see `.claude/CLAUDE.md`
/// "Testing conventions"):
///
/// - `.fast` — pure-logic, sub-millisecond; the default CI PR run.
/// - `.slow` — anything noticeably slower (real I/O, large fixtures, etc.).
///   Consider tagging as `.fast` first and promoting to `.slow` only when
///   the test actually matters for nightly runs.
/// - `.requiresHardware` — needs real microphone, accessibility TCC grant,
///   display server, or user keychain. Skipped on GitHub Actions runners;
///   runs via pre-push on the remote Mac.
///
/// Apply with `@Test(.tags(.fast))` on individual tests, or pass down via
/// `@Suite(.tags(.fast))` to cover a whole file.
extension Tag {
    @Tag public static var fast: Self
    @Tag public static var slow: Self
    @Tag public static var requiresHardware: Self
}
