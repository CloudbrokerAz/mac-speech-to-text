#!/bin/bash
# =============================================================================
# llm-prefetch.sh
# =============================================================================
# Populate the local Gemma 4 E4B-IT model directory from the bundled
# manifest, without launching the .app. Mirrors ModelDownloader.swift:
# size-check + sha256-verify + atomic rename via `<file>.partial`.
#
# Usage: ./scripts/llm-prefetch.sh [options]
#
# Options:
#   --manifest <path>   Path to manifest.json
#                       (default: Sources/Resources/Models/gemma-4-e4b-it-4bit/manifest.json)
#   --dest <path>       Destination model directory. If set, overrides the
#                       Application-Support layout entirely. Equivalent to
#                       the MLX_GEMMA_DIR env var consumed by
#                       MLXGemmaProviderGoldenTests.
#   --bundle-id <id>    Bundle identifier for the Application-Support
#                       layout. Default = com.cloudbroker.mac-speech-to-text
#                       (matches the test fallback when Bundle.main is a
#                       test runner; see ModelDownloader.swift:105/116).
#                       Can also be set via MAC_STT_BUNDLE_ID env var.
#   --quiet             Suppress per-file progress output (errors still emit)
#   --help              Show this help message
#
# Environment:
#   MLX_GEMMA_DIR       Same effect as --dest. Wins over --bundle-id.
#   MAC_STT_BUNDLE_ID   Same effect as --bundle-id.
#
# Exit codes:
#   0  success (or no-op — every file already verified)
#   1  manifest unreadable / malformed
#   2  download failure (network, HTTP non-2xx)
#   3  verification failure (size or sha256 mismatch)
#   4  missing prerequisite (curl / shasum / python3)
#
# Notes:
#   - Idempotent: re-runs are no-ops once every file matches the manifest.
#   - The script does NOT validate the manifest's revision pin against
#     Hugging Face — verification is local-only against the bundled
#     manifest's per-file sha256s.
#   - Source of truth for the URL pattern is ModelDownloader.swift:441-475.
# =============================================================================

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"
DEFAULT_MANIFEST="${PROJECT_ROOT}/Sources/Resources/Models/gemma-4-e4b-it-4bit/manifest.json"
DEFAULT_BUNDLE_ID="com.cloudbroker.mac-speech-to-text"
HF_BASE="https://huggingface.co"

# Terminal colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

# Options
MANIFEST_PATH="${DEFAULT_MANIFEST}"
DEST_OVERRIDE="${MLX_GEMMA_DIR:-}"
BUNDLE_ID="${MAC_STT_BUNDLE_ID:-${DEFAULT_BUNDLE_ID}}"
QUIET=false

# =============================================================================
# Output helpers
# =============================================================================

print_header() {
    [ "$QUIET" = true ] && return
    echo -e "\n${BLUE}============================================================================${NC}"
    echo -e "${BOLD}${CYAN}  $1${NC}"
    echo -e "${BLUE}============================================================================${NC}\n"
}

print_info() {
    [ "$QUIET" = true ] && return
    echo -e "${CYAN}[INFO]${NC} $1"
}

print_success() {
    [ "$QUIET" = true ] && return
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" >&2
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

show_help() {
    # Print the leading comment block: every line starting with `#`,
    # stopping at the first blank line that follows the shebang. Strip
    # the leading `# ` (or just `#`) so the help text reads cleanly.
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
    exit 0
}

# =============================================================================
# Prerequisites
# =============================================================================

require_command() {
    local cmd="$1"
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        print_error "Required command not found: ${cmd}"
        exit 4
    fi
}

# =============================================================================
# Argument parsing
# =============================================================================

while [[ $# -gt 0 ]]; do
    case "$1" in
        --manifest)
            [[ -z "${2:-}" || "${2}" == --* ]] && { print_error "--manifest requires a path"; exit 1; }
            MANIFEST_PATH="$2"
            shift 2
            ;;
        --dest)
            [[ -z "${2:-}" || "${2}" == --* ]] && { print_error "--dest requires a path"; exit 1; }
            DEST_OVERRIDE="$2"
            shift 2
            ;;
        --bundle-id)
            [[ -z "${2:-}" || "${2}" == --* ]] && { print_error "--bundle-id requires a value"; exit 1; }
            BUNDLE_ID="$2"
            shift 2
            ;;
        --quiet)
            QUIET=true
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
# Validation
# =============================================================================

require_command curl
require_command shasum
require_command python3

if [ ! -f "${MANIFEST_PATH}" ]; then
    print_error "Manifest not found: ${MANIFEST_PATH}"
    exit 1
fi

# =============================================================================
# Manifest parsing
#
# Use python3 to extract structural fields — model_id, revision, and the
# per-file (path, size, sha256) tuples. Output a tab-separated stream so
# bash can iterate with `while read`. A null sha256 (manifest entries
# without a hash) is emitted as an empty field.
# =============================================================================

read_manifest_field() {
    # Read a top-level string field from the manifest. Pass the path and
    # field name as argv to keep the Python source free of shell-interpolated
    # values (a path containing a single quote, newline, or backslash would
    # otherwise break the source rather than the resolution).
    local field="$1"
    python3 -c '
import json, sys
path, field = sys.argv[1], sys.argv[2]
with open(path) as f:
    m = json.load(f)
v = m.get(field)
if v is None:
    sys.exit(f"manifest missing field: {field}")
print(v)
' "${MANIFEST_PATH}" "${field}"
}

MODEL_ID="$(read_manifest_field model_id)"
REVISION="$(read_manifest_field revision)"

# Derive the model directory name from model_id (last path component, after
# the final `/`). Mirrors ModelManifest.modelDirectoryName in Sources.
MODEL_DIR_NAME="${MODEL_ID##*/}"
if [ -z "${MODEL_DIR_NAME}" ] || [ "${MODEL_DIR_NAME}" = "${MODEL_ID}" ]; then
    print_error "Malformed model_id (expected 'org/name'): ${MODEL_ID}"
    exit 1
fi

# Resolve destination
if [ -n "${DEST_OVERRIDE}" ]; then
    DEST_DIR="${DEST_OVERRIDE}"
else
    DEST_DIR="${HOME}/Library/Application Support/${BUNDLE_ID}/Models/${MODEL_DIR_NAME}"
fi

print_header "Prefetching ${MODEL_ID} @ ${REVISION:0:8}…"
print_info "Manifest:  ${MANIFEST_PATH}"
print_info "Dest dir:  ${DEST_DIR}"

mkdir -p "${DEST_DIR}"

# =============================================================================
# Per-file iteration
# =============================================================================

# Stream tab-separated `path<TAB>size<TAB>sha256` rows. Empty sha256 means
# size-only verification (matches ModelDownloader.fileSatisfiesManifest).
# Same argv-not-interpolated discipline as read_manifest_field above.
FILE_STREAM="$(python3 -c '
import json, sys
with open(sys.argv[1]) as f:
    m = json.load(f)
for entry in m.get("files", []):
    path = entry["path"]
    size = entry["size"]
    sha = entry.get("sha256") or ""
    print(f"{path}\t{size}\t{sha}")
' "${MANIFEST_PATH}")"

verify_size() {
    # $1 = path, $2 = expected size in bytes
    local path="$1"
    local expected="$2"
    local got
    got="$(stat -f %z "${path}" 2>/dev/null || echo 0)"
    [ "${got}" = "${expected}" ]
}

verify_sha256() {
    # $1 = path, $2 = expected hex
    local path="$1"
    local expected="$2"
    local actual_lc expected_lc
    actual_lc="$(shasum -a 256 "${path}" | awk '{print $1}' | tr 'A-Z' 'a-z')"
    expected_lc="$(echo "${expected}" | tr 'A-Z' 'a-z')"
    [ "${actual_lc}" = "${expected_lc}" ]
}

download_file() {
    # $1 = relative path, $2 = expected size, $3 = expected sha256 (may be empty)
    local rel_path="$1"
    local expected_size="$2"
    local expected_sha="$3"

    local dest="${DEST_DIR}/${rel_path}"
    local partial="${dest}.partial"
    local url="${HF_BASE}/${MODEL_ID}/resolve/${REVISION}/${rel_path}"

    mkdir -p "$(dirname "${dest}")"

    # Idempotency: file already complete + verified.
    if [ -f "${dest}" ] && verify_size "${dest}" "${expected_size}"; then
        if [ -z "${expected_sha}" ]; then
            print_success "verified (size only): ${rel_path}"
            return 0
        fi
        if verify_sha256 "${dest}" "${expected_sha}"; then
            print_success "verified: ${rel_path}"
            return 0
        fi
        print_warning "sha256 mismatch on existing ${rel_path}; re-downloading"
        rm -f "${dest}"
    fi

    # Clean any stale partial.
    rm -f "${partial}"

    print_info "downloading ${rel_path} ($(human_bytes "${expected_size}"))…"

    # `curl -L` follows the HF 302 → CDN redirect. `-f` makes non-2xx fail.
    # `--retry 3` for transient hiccups; `--retry-connrefused` covers DNS
    # blips. `-#` is a brief progress bar; suppress in quiet mode.
    local curl_progress=("-#")
    if [ "$QUIET" = true ]; then
        curl_progress=("-s" "-S")
    fi
    if ! curl -L -f "${curl_progress[@]}" --retry 3 --retry-connrefused \
            -o "${partial}" "${url}"; then
        print_error "download failed: ${rel_path}"
        rm -f "${partial}"
        exit 2
    fi

    if ! verify_size "${partial}" "${expected_size}"; then
        local got
        got="$(stat -f %z "${partial}" 2>/dev/null || echo 0)"
        print_error "size mismatch for ${rel_path}: expected ${expected_size}, got ${got}"
        rm -f "${partial}"
        exit 3
    fi

    if [ -n "${expected_sha}" ]; then
        if ! verify_sha256 "${partial}" "${expected_sha}"; then
            print_error "sha256 mismatch for ${rel_path}"
            rm -f "${partial}"
            exit 3
        fi
    fi

    mv -f "${partial}" "${dest}"
    print_success "verified: ${rel_path}"
}

human_bytes() {
    python3 -c '
import sys
b = float(sys.argv[1])
for unit in ["B", "KB", "MB", "GB", "TB"]:
    if b < 1024:
        print(f"{b:.1f} {unit}")
        break
    b /= 1024
' "$1"
}

# =============================================================================
# Main loop
# =============================================================================

TOTAL_FILES=0
while IFS=$'\t' read -r rel_path expected_size expected_sha; do
    [ -z "${rel_path}" ] && continue
    TOTAL_FILES=$((TOTAL_FILES + 1))
    download_file "${rel_path}" "${expected_size}" "${expected_sha}"
done <<< "${FILE_STREAM}"

print_success "All ${TOTAL_FILES} files verified at ${DEST_DIR}"
