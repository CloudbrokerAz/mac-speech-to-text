#!/bin/bash
# =============================================================================
# llm-reset.sh
# =============================================================================
# Wipe local Gemma model directories under ~/Library/Application Support/
# so the next launch (or `llm-prefetch.sh` run) re-downloads from a clean
# state. Useful for testing the first-run UX, the cutover migration, or
# recovering from a corrupt download.
#
# Usage: ./scripts/llm-reset.sh [options]
#
# Options:
#   --bundle-id <id>    Wipe Models/ under this bundle id only.
#                       (default: wipe both com.cloudbroker.mac-speech-to-text
#                       AND com.speechtotext.app — the test fallback and the
#                       .app's runtime bundle id respectively. See
#                       ModelDownloader.swift:105 / build-app.sh:45.)
#   --path <path>       Wipe an arbitrary path (e.g. an MLX_GEMMA_DIR target).
#                       Bypasses the bundle-id resolution entirely.
#   --legacy            Also remove the v1 gemma-3-text-4b-it-4bit/ directory.
#                       (AppState.purgeLegacyGemma3ModelDirectory() handles
#                       this on launch in the .app, but the standalone
#                       golden-test path may leave it behind.)
#   --yes               Skip the confirmation prompt. Required for CI / scripts.
#   --dry-run           Print what would be removed; remove nothing.
#   --help              Show this help message
#
# Environment:
#   MAC_STT_BUNDLE_ID   Overrides --bundle-id default.
#
# Exit codes:
#   0  removed (or nothing to remove)
#   1  invalid options
#   2  user declined the confirmation prompt
#   3  removal failed
#
# Safety:
#   The script lists every path it intends to remove and (without --yes)
#   prompts for an explicit y/N before touching anything. --yes skips the
#   prompt; --dry-run prints and exits without removing.
# =============================================================================

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================
APP_SUPPORT="${HOME}/Library/Application Support"
DEFAULT_TEST_BUNDLE_ID="com.cloudbroker.mac-speech-to-text"
DEFAULT_APP_BUNDLE_ID="com.speechtotext.app"
LEGACY_MODEL_DIR_NAME="gemma-3-text-4b-it-4bit"

# Terminal colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

# Options
BUNDLE_ID_OVERRIDE="${MAC_STT_BUNDLE_ID:-}"
EXPLICIT_PATH=""
INCLUDE_LEGACY=false
ASSUME_YES=false
DRY_RUN=false

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
# Argument parsing
# =============================================================================

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bundle-id)
            [[ -z "${2:-}" || "${2}" == --* ]] && { print_error "--bundle-id requires a value"; exit 1; }
            BUNDLE_ID_OVERRIDE="$2"
            shift 2
            ;;
        --path)
            [[ -z "${2:-}" || "${2}" == --* ]] && { print_error "--path requires a value"; exit 1; }
            EXPLICIT_PATH="$2"
            shift 2
            ;;
        --legacy)
            INCLUDE_LEGACY=true
            shift
            ;;
        --yes|-y)
            ASSUME_YES=true
            shift
            ;;
        --dry-run|-n)
            DRY_RUN=true
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
# Resolve targets
# =============================================================================

TARGETS=()

if [ -n "${EXPLICIT_PATH}" ]; then
    TARGETS+=("${EXPLICIT_PATH}")
elif [ -n "${BUNDLE_ID_OVERRIDE}" ]; then
    TARGETS+=("${APP_SUPPORT}/${BUNDLE_ID_OVERRIDE}/Models")
else
    # Default: wipe both bundle-id paths. The .app and `swift test` use
    # different bundle ids, so a clean reset wants to clear both.
    TARGETS+=("${APP_SUPPORT}/${DEFAULT_TEST_BUNDLE_ID}/Models")
    TARGETS+=("${APP_SUPPORT}/${DEFAULT_APP_BUNDLE_ID}/Models")
fi

# Filter to only existing paths so the prompt does not list ghosts.
# Always scope removal to the per-model subdirectory (`gemma-4-e4b-it-4bit/`,
# and with --legacy also `gemma-3-text-4b-it-4bit/`) — never the parent
# `Models/` root. A doctor's `Application Support/<bundle>/Models/` may
# also contain unrelated caches (FluidAudio ASR weights, etc.); a `Models/`
# rm -rf would be a data-loss vector.
EXISTING_TARGETS=()
LEGACY_HITS=()
for t in "${TARGETS[@]}"; do
    [ -e "${t}" ] || continue
    CURRENT_DIR="${t}/gemma-4-e4b-it-4bit"
    [ -e "${CURRENT_DIR}" ] && EXISTING_TARGETS+=("${CURRENT_DIR}")
    if [ "${INCLUDE_LEGACY}" = true ]; then
        LEGACY_DIR="${t}/${LEGACY_MODEL_DIR_NAME}"
        [ -e "${LEGACY_DIR}" ] && LEGACY_HITS+=("${LEGACY_DIR}")
    fi
done

# When --path is used, treat it as a literal target (no per-model carve-out).
# Honours the user's explicit choice; protection is on them.
if [ -n "${EXPLICIT_PATH}" ]; then
    EXISTING_TARGETS=()
    LEGACY_HITS=()
    [ -e "${EXPLICIT_PATH}" ] && EXISTING_TARGETS+=("${EXPLICIT_PATH}")
fi

if [ ${#EXISTING_TARGETS[@]} -eq 0 ] && [ ${#LEGACY_HITS[@]} -eq 0 ]; then
    print_info "Nothing to remove."
    exit 0
fi

# =============================================================================
# Confirmation
# =============================================================================

print_header "llm-reset"

print_warning "About to remove the following:"
# bash 3.2 errors under `set -u` when expanding "${arr[@]}" on an empty
# array, so we length-guard each iteration. (See also llm-eval.sh.)
if [ ${#EXISTING_TARGETS[@]} -gt 0 ]; then
    for t in "${EXISTING_TARGETS[@]}"; do
        SIZE="$(du -sh "${t}" 2>/dev/null | awk '{print $1}')"
        echo "  - ${t}  (${SIZE:-?})"
    done
fi
if [ "${INCLUDE_LEGACY}" = true ] && [ ${#LEGACY_HITS[@]} -gt 0 ]; then
    for t in "${LEGACY_HITS[@]}"; do
        SIZE="$(du -sh "${t}" 2>/dev/null | awk '{print $1}')"
        echo "  - ${t}  (${SIZE:-?}) [legacy]"
    done
fi
echo

if [ "${DRY_RUN}" = true ]; then
    print_info "Dry run — no files removed."
    exit 0
fi

if [ "${ASSUME_YES}" = false ]; then
    if [ ! -t 0 ]; then
        print_error "Refusing to delete without --yes in non-interactive mode"
        exit 2
    fi
    echo -n "Continue? (y/N): "
    read -r response
    if [[ ! "${response}" =~ ^[Yy]$ ]]; then
        print_info "Cancelled."
        exit 2
    fi
fi

# =============================================================================
# Removal
# =============================================================================

# Build the removal list with length guards (bash 3.2 + set -u). The
# pre-checks at the top of the script guarantee at least one of the two
# arrays is non-empty by the time we get here.
REMOVE_LIST=()
[ ${#EXISTING_TARGETS[@]} -gt 0 ] && REMOVE_LIST+=("${EXISTING_TARGETS[@]}")
if [ "${INCLUDE_LEGACY}" = true ] && [ ${#LEGACY_HITS[@]} -gt 0 ]; then
    REMOVE_LIST+=("${LEGACY_HITS[@]}")
fi

for t in "${REMOVE_LIST[@]}"; do
    if rm -rf -- "${t}"; then
        print_success "removed ${t}"
    else
        print_error "rm -rf failed for ${t}"
        exit 3
    fi
done

print_success "llm-reset complete"
