#!/usr/bin/env bash
set -euo pipefail

# Fetch the prebuilt CrispASR binary (Linux x86_64) into ~/.cache/crispasr/bin so
# the `crispasr` backend can serve Cohere Transcribe (GGUF) on CPU. CrispASR is a
# whisper.cpp-style ggml runtime: https://github.com/CrispStrobe/CrispASR
#
# Override the release with CRISPASR_RELEASE=<tag> (default: latest).
# Pick a perf variant with CRISPASR_VARIANT (avx512|cuda|cuda13|vulkan); the default
# is the plain, most-portable CPU build.

REPO="CrispStrobe/CrispASR"
CRISPASR_DIR="${CRISPASR_DIR:-$HOME/.cache/crispasr}"
BIN_DIR="$CRISPASR_DIR/bin"
RELEASE="${CRISPASR_RELEASE:-latest}"
OS="$(uname -s)"; ARCH="$(uname -m)"

mkdir -p "$BIN_DIR"

# Map the host arch to CrispASR's asset naming.
case "$ARCH" in
    x86_64|amd64)  A_ARCH="x86_64" ;;
    aarch64|arm64) A_ARCH="arm64" ;;
    *) echo "Unsupported arch: $ARCH"; exit 1 ;;
esac
if [ "$OS" != "Linux" ]; then
    echo "This helper targets Linux. On macOS, CrispASR isn't the default ASR path (use mlx-audio)."
    exit 1
fi

VARIANT="${CRISPASR_VARIANT:-}"                          # empty = plain CPU build
WANT="crispasr-linux-${A_ARCH}${VARIANT:+-$VARIANT}.tar.gz"

api="https://api.github.com/repos/${REPO}/releases/${RELEASE}"
[ "$RELEASE" != "latest" ] && api="https://api.github.com/repos/${REPO}/releases/tags/${RELEASE}"

echo "Looking up CrispASR release ($RELEASE), asset: $WANT …"
# Exact asset match (excludes libcrispasr-* / crispasr-python-* by full filename).
asset_url="$(curl -fsSL "$api" \
    | grep -oE '"browser_download_url": *"[^"]+"' | cut -d'"' -f4 \
    | grep -E "/${WANT}\$" | head -1 || true)"

if [ -z "$asset_url" ]; then
    echo "Error: asset '$WANT' not found in the $RELEASE release of $REPO."
    echo "  Browse: https://github.com/${REPO}/releases  (try a different CRISPASR_VARIANT)"
    exit 1
fi

echo "Downloading: $asset_url"
tmp="$(mktemp -d)"
file="$tmp/$(basename "$asset_url")"
curl -fL "$asset_url" -o "$file"

case "$file" in
    *.tar.gz|*.tgz) tar -xzf "$file" -C "$tmp" ;;
    *.zip)          unzip -q "$file" -d "$tmp" ;;
esac

# Locate the executable named 'crispasr' in whatever we downloaded/extracted.
bin_src="$(find "$tmp" -type f -name crispasr 2>/dev/null | head -1 || true)"
[ -z "$bin_src" ] && [ -f "$file" ] && case "$file" in *crispasr*) bin_src="$file" ;; esac
[ -n "$bin_src" ] || { echo "Error: could not find a 'crispasr' executable in the download."; exit 1; }

install -m 0755 "$bin_src" "$BIN_DIR/crispasr"
# Bundle any shared libs shipped in the tarball into a drop-in lib dir the backend
# adds to LD_LIBRARY_PATH (future-proof: some release variants ship their libs).
LIB_DIR="$CRISPASR_DIR/lib"; mkdir -p "$LIB_DIR"
find "$tmp" -name '*.so*' -exec cp -n {} "$LIB_DIR/" \; 2>/dev/null || true
rm -rf "$tmp"

echo "✓ CrispASR installed: $BIN_DIR/crispasr"

# The prebuilt binary dynamically links libopenblas (+ libgfortran). Check now so
# the failure is obvious here, not as a silent server exit later.
if ! LD_LIBRARY_PATH="$LIB_DIR:${LD_LIBRARY_PATH:-}" ldd "$BIN_DIR/crispasr" 2>/dev/null | grep -q "not found"; then
    echo "  Runtime libraries: OK"
else
    echo ""
    echo "  ⚠ Missing runtime libraries (the binary needs OpenBLAS):"
    LD_LIBRARY_PATH="$LIB_DIR:${LD_LIBRARY_PATH:-}" ldd "$BIN_DIR/crispasr" 2>/dev/null | grep "not found" | sed 's/^/      /'
    echo "  Fix (Debian/Ubuntu):  sudo apt install -y libopenblas0 libgfortran5"
    echo "  No sudo? Drop matching libopenblas.so.0 / libgfortran.so.5 into: $LIB_DIR"
fi

echo "  The Cohere GGUF (~1.5 GB) downloads on first server start to $CRISPASR_DIR."
echo "  Use it: ./scripts/change_model.sh cohere-transcribe-2b  (then ./run.sh)"
