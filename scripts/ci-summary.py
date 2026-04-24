#!/usr/bin/env python3
"""
Emit a structured Markdown summary of a CI job to `$GITHUB_STEP_SUMMARY`
for fast PR triage. Parses `swift build` / `swift test` output captured
to log files.

Usage (inside a GitHub Actions step):

    python3 scripts/ci-summary.py \\
        --job "Build and Test" \\
        --build-log build.log \\
        --test-log test.log \\
        --out "$GITHUB_STEP_SUMMARY"

Any log argument may be omitted — the script only summarises the logs
it's given. Missing or empty logs are noted in the summary.

Why Python (not shell): the parsing is stateful (dedup, bucketing,
severity ordering) and Python's `re` keeps the regex set readable.
macOS-14 runners ship `/usr/bin/env python3` so no extra setup step.
"""

from __future__ import annotations

import argparse
import re
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any


# ---------------------------------------------------------------------------
# Regexes
# ---------------------------------------------------------------------------

# Compiler diagnostic — warning or error.
#   /path/Foo.swift:249:25: warning: cannot use inout ... [#TemporaryPointers]
#   /path/Bar.swift:10:3: error: oops
# The category tag has shipped since Swift 5.10 and most of our noise is
# already tagged; untagged diagnostics fall into an "Uncategorised" bucket.
# Category character class allows `.` and `-` for forward-compat with
# categories like `#StrictConcurrency.Availability`.
SWIFT_DIAG = re.compile(
    r"^(?P<path>[^:\n]+\.swift):(?P<line>\d+):(?P<col>\d+):\s+"
    r"(?P<severity>warning|error):\s+"
    r"(?P<message>.+?)(?:\s+\[#(?P<category>[A-Za-z0-9_.\-]+)\])?$"
)

# Canary: anything diagnostic-shaped. If this matches but SWIFT_DIAG
# doesn't, our regex is stale and we're silently dropping diagnostics —
# the parser surfaces that in the summary rather than rendering a
# misleading "✅ Clean".
SWIFT_DIAG_CANARY = re.compile(
    r"^(?P<path>[^:\n]+\.swift):\d+:\d+:\s+(warning|error|note|remark):"
)

# Swift Testing failure marker.
#   ✘ Test "foo" recorded an issue at Path.swift:42:3
#   ✘ Test "bar" failed after 0.001 seconds.
SWIFT_TEST_FAIL = re.compile(r"^✘ Test \"(?P<name>[^\"]+)\"\s*(?P<rest>.*)$")

# XCTest per-case failure.
#   /path/File.swift:411: error: -[SuiteName.ClassName test_foo] : XCTAssertLessThan failed: ...
XCTEST_FAIL = re.compile(
    r"^(?P<path>[^:\n]+):(?P<line>\d+):\s+error:\s+"
    r"-\[(?P<clazz>[A-Za-z0-9_.]+)\s+(?P<test>[A-Za-z0-9_]+)\]\s*:\s*"
    r"(?P<assertion>.+)$"
)

# Swift Testing run summary.
#   ✔ Test run with 34 tests in 4 suites passed after 0.007 seconds.
#   ✘ Test run with 34 tests in 4 suites failed after 0.012 seconds.
SWIFT_TEST_TOTAL = re.compile(
    r"Test run with (?P<total>\d+) tests?.*\s"
    r"(?P<result>passed|failed)\s+after\s+(?P<secs>[0-9.]+)\s+seconds"
)

# XCTest suite summary (one per suite in --parallel; we take the max).
#   Executed 35 tests, with 0 failures (0 unexpected) in 5.929 (5.935) seconds
XCTEST_TOTAL = re.compile(
    r"Executed\s+(?P<total>\d+)\s+tests?,\s+with\s+(?P<failures>\d+)\s+failure"
)

# Prefixes to strip from file paths so the tables are readable.
RUNNER_PREFIXES = (
    "/Users/runner/work/mac-speech-to-text/mac-speech-to-text/",
    "/Users/runner/_work/mac-speech-to-text/mac-speech-to-text/",
)

# Diagnostic sources to suppress — not our code / not actionable in this PR.
DIAG_IGNORE_PATTERNS = (
    ".build/",              # build cache
    "checkouts/",           # SPM checkouts
    "/Frameworks/",         # vendored frameworks
    "/DerivedData/",
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _strip_prefix(path: str) -> str:
    for pfx in RUNNER_PREFIXES:
        if path.startswith(pfx):
            return path[len(pfx):]
    return path


def _is_our_source(path: str) -> bool:
    for pat in DIAG_IGNORE_PATTERNS:
        if pat in path:
            return False
    return True


def _truncate(msg: str, limit: int = 140) -> str:
    msg = msg.strip()
    if len(msg) <= limit:
        return msg
    return msg[: limit - 1] + "…"


def _read_lines(path: str | None) -> list[str]:
    if not path:
        return []
    p = Path(path)
    if not p.is_file():
        return []
    # errors="replace" guards against odd bytes in compiler output
    # (ANSI colour codes survive utf-8 round-trip; non-utf-8 would not).
    with p.open(encoding="utf-8", errors="replace") as f:
        return [line.rstrip("\n") for line in f]


# ---------------------------------------------------------------------------
# Parsers
# ---------------------------------------------------------------------------

def parse_warnings(path: str | None) -> tuple[dict[str, list[dict[str, str]]], int]:
    """
    Return (buckets, unrecognised) where:
      - buckets is {category: [diagnostic, …]} with file/line/severity/message,
        deduped on (file, line, severity, message);
      - unrecognised counts diagnostic-shaped lines that the full-fidelity
        regex didn't match (canary for regex drift).
    """
    buckets: dict[str, list[dict[str, str]]] = defaultdict(list)
    seen: set[tuple[str, str, str, str]] = set()
    unrecognised = 0
    for line in _read_lines(path):
        m = SWIFT_DIAG.match(line)
        if not m:
            # If it looks like a diagnostic but the full regex failed, bump
            # the canary so the summary can surface a "regex drift" warning.
            canary = SWIFT_DIAG_CANARY.match(line)
            if canary:
                canary_path = _strip_prefix(canary.group("path"))
                if _is_our_source(canary_path):
                    unrecognised += 1
            continue
        file_path = _strip_prefix(m.group("path"))
        if not _is_our_source(file_path):
            continue
        key = (file_path, m.group("line"), m.group("severity"), m.group("message"))
        if key in seen:
            continue
        seen.add(key)
        category = m.group("category") or "Uncategorised"
        buckets[category].append({
            "file": file_path,
            "line": m.group("line"),
            "severity": m.group("severity"),
            "message": m.group("message"),
        })
    return dict(buckets), unrecognised


def parse_test_failures(path: str | None) -> list[dict[str, str]]:
    """Return an ordered list of test failures (XCTest + Swift Testing)."""
    failures: list[dict[str, str]] = []
    for line in _read_lines(path):
        m = XCTEST_FAIL.match(line)
        if m:
            failures.append({
                "kind": "xctest",
                # e.g. SpeechToTextTests.PendingWritesCounterTests → PendingWritesCounterTests
                "class": m.group("clazz").split(".")[-1],
                "test": m.group("test"),
                "assertion": _truncate(m.group("assertion")),
                "location": f"{_strip_prefix(m.group('path'))}:{m.group('line')}",
            })
            continue
        m = SWIFT_TEST_FAIL.match(line)
        if m:
            # SWIFT_TEST_FAIL requires a quoted name, so the run-summary
            # line `✘ Test run with 34 tests …` (unquoted) already can't
            # match here. No extra filter needed.
            failures.append({
                "kind": "swift-testing",
                "name": m.group("name"),
                "detail": _truncate(m.group("rest").strip()),
            })
    return failures


# XCTest's "Test Suite 'Selected tests' (passed|failed)" marks the
# end-of-process line under `--parallel`. Each test-class process emits
# three "Executed N tests" lines (inner suite, `*.xctest` wrapper, and
# `Selected tests`), all with the same N. Summing only the `Executed`
# line that follows the `Selected tests` marker gives one entry per
# process; under non-parallel (single process) that's one entry total.
XCTEST_SELECTED_MARKER = re.compile(r"Test Suite 'Selected tests' (passed|failed)")


def parse_test_totals(path: str | None) -> dict[str, Any]:
    """
    Return {'swift_testing': {…}|None, 'xctest': {…}|None}.

    Swift Testing: the final `Test run with N tests … (passed|failed)` line
    is authoritative; we take the last one we see.

    XCTest: under `--parallel`, each test-class process writes three
    identical "Executed N tests" lines (inner, `*.xctest`, and
    `Selected tests`). We accumulate only the line that follows the
    `Selected tests` marker so per-process totals sum cleanly and no
    suite is silently dropped (previously a `max()` here hid failures
    in non-largest suites — issue #39 review).
    """
    totals: dict[str, Any] = {"swift_testing": None, "xctest": None}
    xctest_total = 0
    xctest_failures = 0
    saw_selected_marker = False

    for line in _read_lines(path):
        m = SWIFT_TEST_TOTAL.search(line)
        if m:
            totals["swift_testing"] = {
                "total": int(m.group("total")),
                "result": m.group("result"),
                "secs": float(m.group("secs")),
            }

        if XCTEST_SELECTED_MARKER.search(line):
            saw_selected_marker = True
            continue

        m = XCTEST_TOTAL.search(line)
        if m and saw_selected_marker:
            xctest_total += int(m.group("total"))
            xctest_failures += int(m.group("failures"))
            saw_selected_marker = False

    if xctest_total > 0 or xctest_failures > 0:
        totals["xctest"] = {"total": xctest_total, "failures": xctest_failures}

    return totals


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

def _log_status(path: str | None) -> str:
    """
    Classify a log path into one of:
      - "absent": caller didn't pass the argument
      - "missing": argument passed but file doesn't exist
      - "empty": file exists but has zero bytes
      - "present": file exists with content
    Distinguishing these is critical: `empty` or `missing` must not render
    as "✅ Clean" — that's exactly the silent-failure mode this script is
    supposed to prevent.
    """
    if not path:
        return "absent"
    p = Path(path)
    if not p.is_file():
        return "missing"
    try:
        if p.stat().st_size == 0:
            return "empty"
    except OSError:
        return "missing"
    return "present"


def render(
    job: str,
    warnings: dict[str, list[dict[str, str]]],
    unrecognised_diag_lines: int,
    failures: list[dict[str, str]],
    totals: dict[str, Any],
    build_log_status: str,
    test_log_status: str,
    job_status: str | None = None,
) -> str:
    lines: list[str] = [f"## {job} — CI summary", ""]

    warn_count = sum(len(v) for v in warnings.values())
    error_count = sum(
        1 for items in warnings.values() for w in items if w["severity"] == "error"
    )
    fail_count = len(failures)

    # Did either log fail to materialise? If so, we can't claim "clean".
    log_problems: list[str] = []
    for label, status in (("build", build_log_status), ("test", test_log_status)):
        if status == "missing":
            log_problems.append(f"{label} log missing (step likely errored before capture)")
        elif status == "empty":
            log_problems.append(f"{label} log empty (0 bytes — `tee` failed or step exited early)")

    # If the caller didn't pass either log at all, nothing to say.
    if build_log_status == "absent" and test_log_status == "absent":
        lines.append("_No build or test log captured — nothing to summarise._")
        lines.append("")
        return "\n".join(lines)

    # Headline chips.
    chips: list[str] = []
    if job_status and job_status.lower() not in ("success", ""):
        chips.append(f"🚨 **Job status: {job_status}**")
    if error_count:
        chips.append(f"🛑 **{error_count}** compile error{'s' if error_count != 1 else ''}")
    if fail_count:
        chips.append(f"❌ **{fail_count}** test failure{'s' if fail_count != 1 else ''}")
    if warn_count - error_count > 0:
        w = warn_count - error_count
        chips.append(f"⚠️ **{w}** warning{'s' if w != 1 else ''}")
    if log_problems:
        chips.append(f"⚠️ **{len(log_problems)}** log capture issue{'s' if len(log_problems) != 1 else ''}")
    if unrecognised_diag_lines:
        chips.append(
            f"🔍 **{unrecognised_diag_lines}** diagnostic-shaped line"
            f"{'s' if unrecognised_diag_lines != 1 else ''} the parser didn't understand"
        )
    if not chips:
        chips.append("✅ **Clean** — no warnings, no failures")
    lines.append(" · ".join(chips))
    lines.append("")

    # Log capture issues section — surfaces cases where we genuinely can't
    # claim to know what happened.
    if log_problems:
        lines.append("### ⚠️ Log capture issues")
        lines.append("")
        for note in log_problems:
            lines.append(f"- {note}")
        lines.append("")
        lines.append(
            "_A summary rendered against missing/empty logs may not reflect the "
            "real build state — check the raw workflow log._"
        )
        lines.append("")

    # Regex drift canary.
    if unrecognised_diag_lines:
        lines.append("### 🔍 Possible regex drift")
        lines.append("")
        lines.append(
            f"- {unrecognised_diag_lines} line(s) matched `\\.swift:N:N: "
            "(warning|error|note|remark):` but not the full parser. Swift's "
            "diagnostic format may have shifted — audit `SWIFT_DIAG` in "
            "`scripts/ci-summary.py` and refresh the `--self-test` corpus."
        )
        lines.append("")

    # Failures.
    if failures:
        lines.append(f"### ❌ Test failures ({fail_count})")
        lines.append("")
        for f in failures[:25]:
            if f["kind"] == "swift-testing":
                lines.append(f"- **{f['name']}**")
                if f["detail"]:
                    lines.append(f"  - {f['detail']}")
            else:
                lines.append(f"- **{f['class']}.{f['test']}**  \\\n  `{f['location']}`")
                lines.append(f"  - {f['assertion']}")
        if fail_count > 25:
            lines.append(f"- _… {fail_count - 25} more; see the raw log_")
        lines.append("")

    # Test totals.
    st = totals.get("swift_testing")
    xc = totals.get("xctest")
    if st or xc:
        lines.append("### 🧪 Test totals")
        lines.append("")
        if st:
            icon = "✅" if st["result"] == "passed" else "❌"
            lines.append(
                f"- {icon} Swift Testing: **{st['total']}** tests — "
                f"{st['result']} in {st['secs']:.2f}s"
            )
        if xc:
            icon = "✅" if xc["failures"] == 0 else "❌"
            lines.append(
                f"- {icon} XCTest: **{xc['total']}** tests — "
                f"**{xc['failures']}** failure{'s' if xc['failures'] != 1 else ''}"
            )
        lines.append("")

    # Diagnostics, grouped by category (errors first, then warnings by count).
    if warnings:
        lines.append(f"### ⚠️ Swift compiler diagnostics ({warn_count})")
        lines.append("")
        lines.append("<details><summary>Expand by category</summary>")
        lines.append("")

        def _cat_sort_key(name: str) -> tuple[int, int, str]:
            items = warnings[name]
            has_error = any(w["severity"] == "error" for w in items)
            # Errors first, then by descending count, then by name.
            return (0 if has_error else 1, -len(items), name)

        for cat in sorted(warnings, key=_cat_sort_key):
            items = warnings[cat]
            lines.append(f"#### `#{cat}` ({len(items)})")
            lines.append("")
            lines.append("| File | Line | Severity | Message |")
            lines.append("|---|---|---|---|")
            for w in items[:20]:
                msg = _truncate(w["message"], 120).replace("|", r"\|")
                file_cell = w["file"].replace("|", r"\|")
                lines.append(
                    f"| `{file_cell}` | {w['line']} | {w['severity']} | {msg} |"
                )
            if len(items) > 20:
                lines.append(f"| _… {len(items) - 20} more_ | | | |")
            lines.append("")
        lines.append("</details>")
        lines.append("")

    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------

SELF_TEST_BUILD = """\
[2/9] Compiling SpeechToText AudioBuffer.swift
/Users/runner/work/mac-speech-to-text/mac-speech-to-text/Sources/Services/AudioCaptureService.swift:249:25: warning: cannot use inout expression here; argument 'mInputData' must be a pointer that outlives the call to 'init(...)' [#TemporaryPointers]
/Users/runner/work/mac-speech-to-text/mac-speech-to-text/Sources/Services/AudioCaptureService.swift:249:25: warning: cannot use inout expression here; argument 'mInputData' must be a pointer that outlives the call to 'init(...)' [#TemporaryPointers]
/Users/runner/work/mac-speech-to-text/mac-speech-to-text/Sources/Services/AudioCaptureService.swift:239:13: warning: variable 'deviceIdSize' was never mutated; consider changing to 'let' constant
/Users/runner/work/mac-speech-to-text/mac-speech-to-text/Sources/SpeechToTextApp/AppDelegate.swift:293:49: warning: call to main actor-isolated instance method 'load()' in a synchronous nonisolated context [#ActorIsolatedCall]
/Users/runner/work/mac-speech-to-text/mac-speech-to-text/Sources/Services/Future.swift:10:3: warning: dotted.compound category example [#StrictConcurrency.Availability]
/Users/runner/work/mac-speech-to-text/mac-speech-to-text/.build/checkouts/FluidAudio/Sources/x.swift:10:1: warning: some dep warning
/Users/runner/work/mac-speech-to-text/mac-speech-to-text/Sources/Mystery.swift:42:1: note: a note line that shouldn't bucket as a diagnostic
/Users/runner/work/mac-speech-to-text/mac-speech-to-text/Sources/DriftTest.swift:99:9: warning: hypothetical future diagnostic with a never-seen tag {category=weirdFuture}
Build complete!
"""

# Multi-process parallel XCTest output — two test classes, each emitting
# the triple `Executed N tests` pattern. Summing without the selected-marker
# filter would triple-count; max() would hide SuiteB's failures entirely.
SELF_TEST_TEST_PARALLEL = """\
Test Suite 'SuiteA' started at 2026-04-24 10:00:00.000.
Test Suite 'SuiteA' passed at 2026-04-24 10:00:00.500.
\t Executed 10 tests, with 0 failures (0 unexpected) in 0.100 (0.200) seconds
Test Suite 'SpeechToTextPackageTests.xctest' passed at 2026-04-24 10:00:00.500.
\t Executed 10 tests, with 0 failures (0 unexpected) in 0.100 (0.200) seconds
Test Suite 'Selected tests' passed at 2026-04-24 10:00:00.500.
\t Executed 10 tests, with 0 failures (0 unexpected) in 0.100 (0.200) seconds
Test Suite 'SuiteB' started at 2026-04-24 10:00:00.600.
/path/B.swift:1: error: -[SpeechToTextTests.SuiteB test_one] : XCTAssertEqual failed
/path/B.swift:2: error: -[SpeechToTextTests.SuiteB test_two] : XCTAssertEqual failed
/path/B.swift:3: error: -[SpeechToTextTests.SuiteB test_three] : XCTAssertEqual failed
Test Suite 'SuiteB' failed at 2026-04-24 10:00:00.900.
\t Executed 5 tests, with 3 failures (0 unexpected) in 0.100 (0.200) seconds
Test Suite 'SpeechToTextPackageTests.xctest' failed at 2026-04-24 10:00:00.900.
\t Executed 5 tests, with 3 failures (0 unexpected) in 0.100 (0.200) seconds
Test Suite 'Selected tests' failed at 2026-04-24 10:00:00.900.
\t Executed 5 tests, with 3 failures (0 unexpected) in 0.100 (0.200) seconds
"""

SELF_TEST_TEST_FAIL = """\
✔ Test "UUIDs produced in quick succession are distinct" passed after 0.001 seconds.
/Users/runner/work/mac-speech-to-text/mac-speech-to-text/Tests/SpeechToTextTests/Services/AudioCaptureServiceTests.swift:411: error: -[SpeechToTextTests.PendingWritesCounterTests test_waitForCompletion_waitsForPendingWrites] : XCTAssertLessThan failed: ("0.204306960105896") is not less than ("0.2")
✘ Test "Some flaky Swift Testing test" failed after 0.002 seconds.
Test Suite 'Selected tests' failed at 2026-04-24 10:00:00.900.
\t Executed 35 tests, with 1 failures (0 unexpected) in 5.929 (5.935) seconds
✔ Test run with 34 tests in 4 suites passed after 0.007 seconds.
"""

SELF_TEST_TEST_CLEAN = """\
✔ Test "UUIDs produced in quick succession are distinct" passed after 0.001 seconds.
Test Suite 'Selected tests' passed at 2026-04-24 10:00:00.000.
\t Executed 35 tests, with 0 failures (0 unexpected) in 5.929 (5.935) seconds
✔ Test run with 34 tests in 4 suites passed after 0.007 seconds.
"""


def _self_test() -> int:
    import tempfile

    failures_found = 0

    def _write_tmp(contents: str) -> str:
        fd = tempfile.NamedTemporaryFile(mode="w", delete=False, suffix=".log")
        fd.write(contents)
        fd.close()
        return fd.name

    def _assert(cond: bool, message: str) -> None:
        nonlocal failures_found
        if not cond:
            print(f"FAIL: {message}", file=sys.stderr)
            failures_found += 1
        else:
            print(f"ok  : {message}")

    # --- parse_warnings ---

    build_path = _write_tmp(SELF_TEST_BUILD)
    warnings, unrecognised = parse_warnings(build_path)
    _assert("TemporaryPointers" in warnings, "TemporaryPointers category bucketed")
    _assert("ActorIsolatedCall" in warnings, "ActorIsolatedCall category bucketed")
    _assert("Uncategorised" in warnings, "uncategorised diagnostic bucketed")
    _assert(
        "StrictConcurrency.Availability" in warnings,
        "dotted category name (\".\") parsed",
    )
    _assert(len(warnings["TemporaryPointers"]) == 1, "duplicate diagnostic deduped")
    all_files = {w["file"] for items in warnings.values() for w in items}
    _assert(
        all(not f.startswith("/Users/runner") for f in all_files),
        "runner workspace prefix stripped",
    )
    _assert(
        all(".build/" not in f for f in all_files),
        "build-cache diagnostics filtered",
    )
    _assert(
        unrecognised >= 1,
        "note-shaped line counted by the drift canary",
    )

    # --- parse_test_failures ---

    fail_path = _write_tmp(SELF_TEST_TEST_FAIL)
    failures = parse_test_failures(fail_path)
    _assert(len(failures) == 2, "two test failures parsed (xctest + swift-testing)")
    xc = next((f for f in failures if f["kind"] == "xctest"), None)
    _assert(xc is not None and xc["class"] == "PendingWritesCounterTests",
            "xctest class extracted")
    _assert(xc is not None and "XCTAssertLessThan failed" in xc["assertion"],
            "xctest assertion captured")
    st = next((f for f in failures if f["kind"] == "swift-testing"), None)
    _assert(st is not None and st["name"] == "Some flaky Swift Testing test",
            "swift testing name captured")

    # --- parse_test_totals: single-process ---

    totals = parse_test_totals(fail_path)
    _assert(totals["swift_testing"] is not None
            and totals["swift_testing"]["total"] == 34,
            "swift testing total parsed")
    _assert(totals["xctest"] is not None
            and totals["xctest"]["total"] == 35
            and totals["xctest"]["failures"] == 1,
            "xctest total+failures parsed (single process)")

    # --- parse_test_totals: parallel / multi-process (regression test for
    # the bug the code-reviewer flagged — previously the `max()` version
    # reported 10/0 instead of 15/3, hiding SuiteB's failures). ---

    parallel_path = _write_tmp(SELF_TEST_TEST_PARALLEL)
    parallel_totals = parse_test_totals(parallel_path)
    _assert(
        parallel_totals["xctest"] is not None
        and parallel_totals["xctest"]["total"] == 15,
        "parallel xctest total sums across processes (was: max, hid suites)",
    )
    _assert(
        parallel_totals["xctest"] is not None
        and parallel_totals["xctest"]["failures"] == 3,
        "parallel xctest failures sum across processes",
    )

    # --- _log_status ---

    import os
    _assert(_log_status(None) == "absent", "_log_status absent")
    _assert(_log_status("/nonexistent/path.log") == "missing", "_log_status missing")
    empty_path = _write_tmp("")
    _assert(_log_status(empty_path) == "empty", "_log_status empty")
    _assert(_log_status(build_path) == "present", "_log_status present")

    # --- render: clean run ---

    clean_path = _write_tmp(SELF_TEST_TEST_CLEAN)
    body = render(
        job="Self test",
        warnings={},
        unrecognised_diag_lines=0,
        failures=parse_test_failures(clean_path),
        totals=parse_test_totals(clean_path),
        build_log_status="present",
        test_log_status="present",
    )
    _assert("Clean" in body, "clean run renders a 'Clean' headline")
    _assert("Test failures" not in body, "clean run has no failures section")
    _assert("Swift compiler diagnostics" not in body,
            "clean run has no diagnostics section")

    # --- render: with failures + warnings + drift canary ---

    body = render(
        job="Build and Test",
        warnings=warnings,
        unrecognised_diag_lines=unrecognised,
        failures=failures,
        totals=totals,
        build_log_status="present",
        test_log_status="present",
    )
    _assert("Test failures (2)" in body, "failures headline rendered")
    _assert("`#TemporaryPointers`" in body, "category heading rendered")
    _assert("PendingWritesCounterTests.test_waitForCompletion_waitsForPendingWrites" in body,
            "xctest case rendered")
    _assert("regex drift" in body.lower(), "regex drift canary surfaced in render")

    # --- render: missing/empty log must NOT claim "Clean" ---

    missing_body = render(
        job="Build and Test",
        warnings={},
        unrecognised_diag_lines=0,
        failures=[],
        totals={"swift_testing": None, "xctest": None},
        build_log_status="missing",
        test_log_status="absent",
    )
    _assert("Clean" not in missing_body,
            "missing build log does NOT render 'Clean'")
    _assert("log missing" in missing_body.lower(),
            "missing-log headline surfaced")

    empty_body = render(
        job="Build and Test",
        warnings={},
        unrecognised_diag_lines=0,
        failures=[],
        totals={"swift_testing": None, "xctest": None},
        build_log_status="empty",
        test_log_status="absent",
    )
    _assert("Clean" not in empty_body,
            "empty build log does NOT render 'Clean'")
    _assert("0 bytes" in empty_body,
            "empty-log headline surfaced")

    # --- render: job_status != success propagates to the headline ---

    failed_job_body = render(
        job="Build and Test",
        warnings={},
        unrecognised_diag_lines=0,
        failures=[],
        totals={"swift_testing": None, "xctest": None},
        build_log_status="present",
        test_log_status="present",
        job_status="failure",
    )
    _assert("Job status: failure" in failed_job_body,
            "non-success job_status surfaced in render")

    # --- _cap_body: large input gets truncated cleanly ---

    big = "x" * (STEP_SUMMARY_SOFT_CAP_BYTES + 50_000)
    capped = _cap_body(big)
    _assert(
        len(capped.encode("utf-8")) <= STEP_SUMMARY_SOFT_CAP_BYTES + 500,
        "_cap_body enforces the step-summary soft cap",
    )
    _assert("truncated" in capped, "_cap_body annotates truncation")

    # --- pipe-escape in file cell (defensive) ---

    pipe_warn = {
        "Test": [{
            "file": "Sources/Weird|Name.swift",
            "line": "1",
            "severity": "warning",
            "message": "pipe|in|message",
        }]
    }
    pipe_body = render(
        job="Build and Test",
        warnings=pipe_warn,
        unrecognised_diag_lines=0,
        failures=[],
        totals={"swift_testing": None, "xctest": None},
        build_log_status="present",
        test_log_status="present",
    )
    _assert(r"Weird\|Name" in pipe_body, "pipe in file cell escaped")
    _assert(r"pipe\|in\|message" in pipe_body, "pipe in message cell escaped")

    # Clean up tmp files
    for p in (build_path, fail_path, clean_path, empty_path, parallel_path):
        try:
            os.unlink(p)
        except OSError:
            pass

    if failures_found:
        print(f"\n{failures_found} self-test failure(s).", file=sys.stderr)
        return 1
    print("\nAll self-tests passed.")
    return 0


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

# GitHub's `$GITHUB_STEP_SUMMARY` is capped at 1 MiB. We aim well under
# to leave room for any preceding summary content the step emitted.
STEP_SUMMARY_SOFT_CAP_BYTES = 900 * 1024


def _cap_body(body: str) -> str:
    """Truncate body if it would blow past the step-summary size cap."""
    encoded = body.encode("utf-8")
    if len(encoded) <= STEP_SUMMARY_SOFT_CAP_BYTES:
        return body
    # Chop at a line boundary near the cap, preserving the first block.
    truncated = encoded[:STEP_SUMMARY_SOFT_CAP_BYTES].decode("utf-8", errors="ignore")
    last_newline = truncated.rfind("\n")
    if last_newline > 0:
        truncated = truncated[:last_newline]
    truncated += (
        "\n\n_… summary truncated near the 1 MiB step-summary cap. "
        "Full diagnostics are in the raw workflow log._\n"
    )
    return truncated


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--job", help="Job name for the summary heading.")
    ap.add_argument("--build-log", help="Path to the captured swift build output.")
    ap.add_argument("--test-log", help="Path to the captured swift test output.")
    ap.add_argument("--job-status",
                    help="Pass `${{ job.status }}` from the workflow so the "
                         "summary can flag non-success jobs explicitly.")
    ap.add_argument("--out", help="Destination file (usually $GITHUB_STEP_SUMMARY).")
    ap.add_argument("--self-test", action="store_true",
                    help="Run parser/render sanity checks and exit.")
    args = ap.parse_args()

    if args.self_test:
        return _self_test()

    if not args.job or not args.out:
        ap.error("--job and --out are required unless --self-test is set")

    try:
        warnings, unrecognised = parse_warnings(args.build_log)
        failures = parse_test_failures(args.test_log)
        totals = parse_test_totals(args.test_log)

        body = render(
            job=args.job,
            warnings=warnings,
            unrecognised_diag_lines=unrecognised,
            failures=failures,
            totals=totals,
            build_log_status=_log_status(args.build_log),
            test_log_status=_log_status(args.test_log),
            job_status=args.job_status,
        )
        body = _cap_body(body)
    except Exception as exc:  # noqa: BLE001 — broad catch is the whole point
        # Never silently swallow: the summary is a diagnostic tool; a
        # diagnostic tool that hides its own failures is worse than useless.
        # Emit a visible fallback so the reviewer knows *something* went wrong
        # with the summary step even if the job itself was green.
        body = (
            f"## {args.job} — CI summary\n\n"
            f"🚨 **Summary generator crashed:** `{type(exc).__name__}: {exc}`\n\n"
            f"_See the raw workflow log for the underlying build/test output. "
            f"If this keeps happening, check `scripts/ci-summary.py` and run "
            f"`python3 scripts/ci-summary.py --self-test` locally._\n"
        )

    # Append to step summary. If the target is unwritable (permission,
    # quota), fall back to stdout — still visible in the workflow log.
    try:
        with open(args.out, "a", encoding="utf-8") as f:
            f.write(body)
            f.write("\n")
    except OSError as exc:
        print(f"::warning::ci-summary: failed to write to {args.out}: {exc}",
              file=sys.stderr)

    # Also echo to stdout so the content is part of the standard log.
    print(body)
    return 0


if __name__ == "__main__":
    sys.exit(main())
