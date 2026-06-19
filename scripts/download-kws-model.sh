#!/bin/bash
# download-kws-model.sh
# Downloads the sherpa-onnx keyword spotting model for voice trigger feature
#
# Source: https://github.com/k2-fsa/sherpa-onnx/releases/tag/kws-models
# Documentation: https://k2-fsa.github.io/sherpa/onnx/kws/index.html

set -euo pipefail

# Configuration
MODEL_NAME="sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01"
MODEL_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/kws-models/${MODEL_NAME}.tar.bz2"
# Pinned sha256 for the release tarball (SEC-6). Update when changing MODEL_NAME/URL.
EXPECTED_SHA256="f170013b4716e41b62b9bfd809687c207cef798ef9bc6534d524e17af9b6561a"

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
RESOURCES_DIR="${PROJECT_ROOT}/Resources"
MODELS_DIR="${RESOURCES_DIR}/Models"
KWS_MODEL_DIR="${MODELS_DIR}/kws"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kws-model-download.XXXXXX")"
trap 'rm -rf "${TEMP_DIR}"' EXIT

verify_sha256() {
    local file="$1"
    local expected="$2"
    if [[ "${#expected}" -ne 64 ]]; then
        echo "Error: EXPECTED_SHA256 must be a 64-character hex digest" >&2
        exit 1
    fi
    local actual
    if command -v shasum &>/dev/null; then
        actual=$(shasum -a 256 "${file}" | awk '{print $1}')
    elif command -v sha256sum &>/dev/null; then
        actual=$(sha256sum "${file}" | awk '{print $1}')
    else
        echo "Error: shasum or sha256sum required for verification" >&2
        exit 1
    fi
    if [[ "${actual}" != "${expected}" ]]; then
        echo "Error: sha256 mismatch for ${file}" >&2
        echo "  expected: ${expected}" >&2
        echo "  actual:   ${actual}" >&2
        exit 1
    fi
}

echo "=== Sherpa-ONNX Keyword Spotting Model Downloader ==="
echo ""
echo "Model: ${MODEL_NAME}"
echo "Source: ${MODEL_URL}"
echo ""

# Check if model already exists
if [[ -d "${KWS_MODEL_DIR}/${MODEL_NAME}" ]]; then
    echo "Model already exists at: ${KWS_MODEL_DIR}/${MODEL_NAME}"
    read -r -p "Do you want to re-download? (y/N): " -n 1 REPLY
    echo
    if [[ ! ${REPLY} =~ ^[Yy]$ ]]; then
        echo "Skipping download."
        exit 0
    fi
    rm -rf "${KWS_MODEL_DIR}/${MODEL_NAME}"
fi

mkdir -p "${KWS_MODEL_DIR}"

echo "Downloading model (this may take a moment)..."
TARBALL="${TEMP_DIR}/${MODEL_NAME}.tar.bz2"

if command -v curl &>/dev/null; then
    curl -fSL --progress-bar -o "${TARBALL}" "${MODEL_URL}"
elif command -v wget &>/dev/null; then
    wget --show-progress -O "${TARBALL}" "${MODEL_URL}"
else
    echo "Error: Neither curl nor wget found. Please install one of them." >&2
    exit 1
fi

if [[ ! -f "${TARBALL}" ]]; then
    echo "Error: Download failed" >&2
    exit 1
fi

echo "Verifying sha256..."
verify_sha256 "${TARBALL}" "${EXPECTED_SHA256}"

FILE_SIZE=$(stat -f%z "${TARBALL}" 2>/dev/null || stat -c%s "${TARBALL}" 2>/dev/null)
echo "Downloaded and verified: ${FILE_SIZE} bytes"

echo "Extracting model..."
tar xjf "${TARBALL}" -C "${TEMP_DIR}"

echo "Installing model to ${KWS_MODEL_DIR}..."
mv "${TEMP_DIR}/${MODEL_NAME}" "${KWS_MODEL_DIR}/"

echo ""
echo "=== Model Contents ==="
ls -la "${KWS_MODEL_DIR}/${MODEL_NAME}/"

echo ""
echo "=== Download Complete ==="
echo "Model installed to: ${KWS_MODEL_DIR}/${MODEL_NAME}"
