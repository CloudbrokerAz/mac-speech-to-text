#!/bin/bash
# =============================================================================
# llm-eval.sh
# =============================================================================
# Run the hardware-gated MLXGemmaProviderGoldenTests end-to-end on
# M-series Apple Silicon. Calls llm-prefetch.sh first to ensure the
# model directory is present, then runs the gated suite with timing +
# peak-RSS instrumentation via /usr/bin/time.
#
# Usage: ./scripts/llm-eval.sh [options]
#
# Options:
#   --dest <path>       Forward to llm-prefetch.sh (override model directory).
#                       Equivalent to MLX_GEMMA_DIR.
#   --bundle-id <id>    Forward to llm-prefetch.sh (override bundle id used
#                       for Application-Support layout).
#   --skip-prefetch     Skip the prefetch step (assume model already present).
#                       Useful when the model lives at a custom location
#                       managed outside this script.
#   --filter <name>     Test filter passed to swift test --filter
#                       (default: MLXGemmaProviderGoldenTests)
#   --release           Run tests in release configuration (faster MLX
#                       inference; also exposes any release-only build issue).
#   --no-parallel       Drop --parallel from swift test invocation.
#                       Default keeps it for parity with `swift test --parallel`.
#   --help              Show this help message
#
# Environment:
#   MLX_GEMMA_DIR       Same as --dest. Forwarded to swift test.
#   MAC_STT_BUNDLE_ID   Same as --bundle-id. Forwarded to llm-prefetch.
#   RUN_MLX_GOLDEN      Force-set to 1 by this script. Required by the
#                       MLXGemmaProviderGoldenTests gate.
#
# Exit codes:
#   0  golden tests passed
#   1  prefetch failure
#   2  test failure
#   3  not on macOS / Apple Silicon
#
# Notes:
#   - Wall-clock + peak resident memory are reported via /usr/bin/time -l.
#     Per-token latency is surfaced inside the test's own #expect block;
#     #18 acceptance for "before/after benchmarks" lives there.
#   - Tests are tagged .requiresHardware, so this script is for local
#     hardware runs or the nightly remote-Mac job — not the default
#     CI path.
# =============================================================================

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"

# Terminal colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

# Defaults
DEST_OVERRIDE="${MLX_GEMMA_DIR:-}"
BUNDLE_ID_OVERRIDE="${MAC_STT_BUNDLE_ID:-}"
SKIP_PREFETCH=false
TEST_FILTER="MLXGemmaProviderGoldenTests"
BUILD_CONFIG="debug"
USE_PARALLEL=true

# =============================================================================
# Output helpers
# =============================================================================

print_header() {
    echo -e "\n${BLUE}============================================================================${NC}"
    echo -e "${BOLD}${CYAN}  $1${NC}"
    echo -e "${BLUE}============================================================================${NC}\n"
}

print_info() {
    echo -e "${CYAN}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" >&2
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

show_help() {
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
    exit 0
}

# =============================================================================
# Platform check
# =============================================================================

if [[ "$(uname -s)" != "Darwin" ]]; then
    print_error "llm-eval.sh requires macOS (MLX is Apple-Silicon-only)"
    exit 3
fi

if [[ "$(uname -m)" != "arm64" ]]; then
    print_warning "host is not arm64 (uname -m = $(uname -m)); MLX inference will not run"
fi

# =============================================================================
# Argument parsing
# =============================================================================

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dest)
            [[ -z "${2:-}" || "${2}" == --* ]] && { print_error "--dest requires a path"; exit 1; }
            DEST_OVERRIDE="$2"
            shift 2
            ;;
        --bundle-id)
            [[ -z "${2:-}" || "${2}" == --* ]] && { print_error "--bundle-id requires a value"; exit 1; }
            BUNDLE_ID_OVERRIDE="$2"
            shift 2
            ;;
        --skip-prefetch)
            SKIP_PREFETCH=true
            shift
            ;;
        --filter)
            [[ -z "${2:-}" || "${2}" == --* ]] && { print_error "--filter requires a value"; exit 1; }
            TEST_FILTER="$2"
            shift 2
            ;;
        --release)
            BUILD_CONFIG="release"
            shift
            ;;
        --no-parallel)
            USE_PARALLEL=false
            shift
            ;;
        --help|-h)
            show_help
            ;;
        *)
            print_error "Unknown option: $1"
            echo "Use --help for usage information" >&2
            exit 1
            ;;
    esac
done

# =============================================================================
# Prefetch
# =============================================================================

cd "${PROJECT_ROOT}"

if [ "${SKIP_PREFETCH}" = true ]; then
    print_info "Skipping prefetch (--skip-prefetch)"
else
    print_header "Prefetching Gemma 4 weights"
    # Build args incrementally. macOS `/bin/bash` 3.2 errors under `set -u`
    # when expanding an empty array via "${arr[@]}", so we length-guard the
    # invocation rather than relying on `${arr[@]+…}` syntax (which works
    # but reads as a workaround on every call site).
    PREFETCH_ARGS=()
    [ -n "${DEST_OVERRIDE}" ] && PREFETCH_ARGS+=("--dest" "${DEST_OVERRIDE}")
    [ -n "${BUNDLE_ID_OVERRIDE}" ] && PREFETCH_ARGS+=("--bundle-id" "${BUNDLE_ID_OVERRIDE}")
    if [ ${#PREFETCH_ARGS[@]} -gt 0 ]; then
        "${SCRIPT_DIR}/llm-prefetch.sh" "${PREFETCH_ARGS[@]}" || { print_error "Prefetch failed"; exit 1; }
    else
        "${SCRIPT_DIR}/llm-prefetch.sh" || { print_error "Prefetch failed"; exit 1; }
    fi
fi

# =============================================================================
# Environment for swift test
# =============================================================================
# RUN_MLX_GOLDEN=1 unlocks the @Suite gate in MLXGemmaProviderGoldenTests
# (Tests/SpeechToTextTests/Services/MLXGemmaProviderTests.swift:148-150).
# MLX_GEMMA_DIR (when --dest is set) overrides the default
# Application-Support lookup at line 153.

export RUN_MLX_GOLDEN=1
if [ -n "${DEST_OVERRIDE}" ]; then
    export MLX_GEMMA_DIR="${DEST_OVERRIDE}"
fi

print_header "Running ${TEST_FILTER}"
print_info "RUN_MLX_GOLDEN=1"
[ -n "${MLX_GEMMA_DIR:-}" ] && print_info "MLX_GEMMA_DIR=${MLX_GEMMA_DIR}"
print_info "Configuration: ${BUILD_CONFIG}"

# =============================================================================
# swift test invocation, wrapped in /usr/bin/time -l for peak RSS
# =============================================================================
# /usr/bin/time -l is the BSD time on macOS; trailing block includes
# `maximum resident set size` in bytes plus user/sys/wall seconds.
# Output goes to stderr — we tee it to a log file for easy inspection.

LOG_DIR="${PROJECT_ROOT}/build/llm-eval"
mkdir -p "${LOG_DIR}"
TIME_LOG="${LOG_DIR}/eval-$(date +%Y%m%d-%H%M%S).log"

SWIFT_TEST_ARGS=("test" "--filter" "${TEST_FILTER}")
if [ "${USE_PARALLEL}" = true ]; then
    SWIFT_TEST_ARGS+=("--parallel")
fi
if [ "${BUILD_CONFIG}" = "release" ]; then
    SWIFT_TEST_ARGS+=("-c" "release")
fi

print_info "Logging timing to: ${TIME_LOG}"
echo

# Stream `time -l`'s combined stderr (swift's test output + the trailing
# rusage block) directly to TIME_LOG, then `cat` it back to the user's
# console after the run. Bash does not wait on `>(tee …)` process-sub
# children — without this, the subsequent awk reads at the bottom of
# this script could race against an unflushed log file.
set +e
/usr/bin/time -l swift "${SWIFT_TEST_ARGS[@]}" 2> "${TIME_LOG}"
TEST_EXIT=$?
set -e
# Echo the captured stderr back so the user sees swift test output even
# though we redirected it. (Removing the `2>` would lose the rusage trailer.)
[ -f "${TIME_LOG}" ] && cat "${TIME_LOG}" >&2

# =============================================================================
# Summary
# =============================================================================

print_header "Eval summary"

if [ ${TEST_EXIT} -ne 0 ]; then
    print_error "swift test exited ${TEST_EXIT}"
fi

# Pull the salient values from /usr/bin/time -l output. macOS emits the
# triple `<real> real    <user> user    <sys> sys` on a single line, so a
# bare `/real/` regex would match the same row that `/user/` and `/sys/`
# match — silently reporting the wall-clock value under three labels. We
# walk the fields and grab the value preceding each label.
if [ -f "${TIME_LOG}" ]; then
    REAL_S="$(awk '{ for(i=1;i<=NF;i++) if($i=="real") { print $(i-1); exit } }' "${TIME_LOG}" 2>/dev/null || true)"
    USER_S="$(awk '{ for(i=1;i<=NF;i++) if($i=="user") { print $(i-1); exit } }' "${TIME_LOG}" 2>/dev/null || true)"
    SYS_S="$(awk  '{ for(i=1;i<=NF;i++) if($i=="sys")  { print $(i-1); exit } }' "${TIME_LOG}" 2>/dev/null || true)"
    PEAK_RSS_B="$(awk '/maximum resident set size/ {print $1; exit}' "${TIME_LOG}" 2>/dev/null || true)"
    PEAK_FOOTPRINT_B="$(awk '/peak memory footprint/ {print $1; exit}' "${TIME_LOG}" 2>/dev/null || true)"

    [ -n "${REAL_S}" ] && print_info "Wall:       ${REAL_S} s"
    [ -n "${USER_S}" ] && print_info "User CPU:   ${USER_S} s"
    [ -n "${SYS_S}" ]  && print_info "Sys CPU:    ${SYS_S} s"
    if [ -n "${PEAK_RSS_B}" ]; then
        # macOS reports peak RSS in bytes; print in MB for readability.
        PEAK_RSS_MB="$(python3 -c 'import sys; print(f"{int(sys.argv[1]) / (1024 * 1024):.1f}")' "${PEAK_RSS_B}" 2>/dev/null || echo "?")"
        print_info "Peak RSS:   ${PEAK_RSS_MB} MB (${PEAK_RSS_B} B)"
    fi
    if [ -n "${PEAK_FOOTPRINT_B}" ]; then
        PEAK_FOOTPRINT_MB="$(python3 -c 'import sys; print(f"{int(sys.argv[1]) / (1024 * 1024):.1f}")' "${PEAK_FOOTPRINT_B}" 2>/dev/null || echo "?")"
        print_info "Peak mem:   ${PEAK_FOOTPRINT_MB} MB (${PEAK_FOOTPRINT_B} B)"
    fi
fi

if [ ${TEST_EXIT} -eq 0 ]; then
    print_success "Golden tests passed"
else
    print_error "Golden tests failed"
fi

exit ${TEST_EXIT}
