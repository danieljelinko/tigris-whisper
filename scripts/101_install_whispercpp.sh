#!/usr/bin/env bash
set -euo pipefail

# One-time setup for the native whisper.cpp backend.
#   Linux  → CPU build (the no-GPU fallback; also the shared artifact that de-risks Mac)
#   Darwin → Metal build (Phase 2; Metal is on by default in whisper.cpp on Apple Silicon)
# Clones + builds whisper-server and downloads the default ggml model.

WHISPERCPP_DIR="${WHISPERCPP_DIR:-$HOME/.cache/whisper.cpp}"
REPO_DIR="$WHISPERCPP_DIR/repo"
MODEL_NAME="${WHISPERCPP_MODEL_NAME:-large-v3-turbo-q5_0}"
REPO_URL="https://github.com/ggml-org/whisper.cpp.git"
OS="$(uname -s)"

MODEL_DIR="${WHISPERCPP_DIR}/models"
MODEL_FILE="${MODEL_DIR}/ggml-${MODEL_NAME}.bin"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-${MODEL_NAME}.bin"

echo "whisper.cpp setup (os: $OS)"

mkdir -p "$MODEL_DIR"

# ─── macOS: prefer Homebrew (30 sec) over cmake (10+ min) ────────────────────
if [ "$OS" = "Darwin" ]; then
    command -v brew >/dev/null || {
        echo "Error: Homebrew not installed. Install it first:"
        echo "  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
        exit 1
    }
    echo "Installing whisper.cpp via Homebrew (includes Metal acceleration)…"
    brew install whisper-cpp
    SERVER_BIN="$(brew --prefix)/bin/whisper-server"

# ─── Linux: cmake build ───────────────────────────────────────────────────────
else
    for t in git cmake; do
        command -v "$t" >/dev/null || { echo "Error: '$t' is required. Install it first."; exit 1; }
    done

    if [ -d "$REPO_DIR/.git" ]; then
        echo "Updating existing checkout…"; git -C "$REPO_DIR" pull --ff-only || true
    else
        git clone --depth 1 "$REPO_URL" "$REPO_DIR"
    fi

    cmake -S "$REPO_DIR" -B "$REPO_DIR/build" -DWHISPER_BUILD_SERVER=ON
    cmake --build "$REPO_DIR/build" --config Release -j --target whisper-server
    SERVER_BIN="$REPO_DIR/build/bin/whisper-server"
fi

[ -x "$SERVER_BIN" ] || { echo "Error: whisper-server not found at $SERVER_BIN"; exit 1; }

# ─── Download model ────────────────────────────────────────────────────────────
if [ -f "$MODEL_FILE" ]; then
    echo "✓ Model already present: $MODEL_FILE"
else
    echo "Downloading model '${MODEL_NAME}' (~570 MB)…"
    command -v curl >/dev/null || { echo "Error: curl required for model download"; exit 1; }
    curl -L --progress-bar -o "$MODEL_FILE" "$MODEL_URL"
fi
[ -f "$MODEL_FILE" ] || { echo "Error: model not found at $MODEL_FILE"; exit 1; }

echo ""
echo "✓ whisper.cpp ready"
echo "  server: $SERVER_BIN"
echo "  model:  $MODEL_FILE"
echo ""
echo "Then run:  ./run.sh"
