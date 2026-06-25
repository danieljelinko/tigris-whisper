#!/usr/bin/env bash
set -euo pipefail

# Single entry point for tigris-whisper.
# Auto-detects the host platform and GPU, brings up the right transcription
# backend, then launches the OS-appropriate daemon.
#
# Dispatch:
#   Darwin              → mlx-whisper
#   Linux + NVIDIA GPU  → Docker + CUDA   (existing proven path)
#   Linux, no GPU       → faster-whisper CPU (whisper.cpp CPU available via override)
#
# Overrides:
#   WHISPER_BACKEND=docker_cuda|whispercpp_cpu|whispercpp_metal|mlx  (skip detection)
#   WHISPER_MLX_MODEL=mlx-community/whisper-small-mlx-q4            (macOS model)
#   WHISPER_LANG=fr    language hint passed through to the daemon
#
# Dry-run:
#   ./run.sh --print-backend   print selected backend and exit (no daemon started)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CONFIG_FILE="$SCRIPT_DIR/tigris-whisper.env"
USER_WHISPER_MLX_MODEL="${WHISPER_MLX_MODEL:-}"
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    set -a; source "$CONFIG_FILE"; set +a
fi
[ -n "$USER_WHISPER_MLX_MODEL" ] && export WHISPER_MLX_MODEL="$USER_WHISPER_MLX_MODEL"

PRINT_ONLY=0
for arg in "$@"; do [ "$arg" = "--print-backend" ] && PRINT_ONLY=1; done

OS="$(uname -s)"
PIXI="$(command -v pixi 2>/dev/null || printf '%s/.pixi/bin/pixi' "$HOME")"

# ─── Check common dependencies ────────────────────────────────────────────────

if [ "$PRINT_ONLY" = "0" ]; then
    if [ "$OS" = "Darwin" ]; then
        [ -x "$PIXI" ] || { echo "Error: pixi is not installed (run ./install.sh)"; exit 1; }
    else
        command -v uv >/dev/null || {
            echo "Error: uv is not installed (curl -LsSf https://astral.sh/uv/install.sh | sh)"
            exit 1
        }
        command -v sox >/dev/null || { echo "Error: sox not installed (sudo apt install sox)"; exit 1; }
    fi
fi

# ─── Detect platform + GPU ────────────────────────────────────────────────────

HAS_GPU_FLAG=""
if [ "$OS" = "Linux" ] && command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
    HAS_GPU_FLAG="--has-nvidia-gpu"
fi

run_python() {
    if [ "$OS" = "Darwin" ]; then
        [ -x "$PIXI" ] || { echo "Error: pixi is not installed (run ./install.sh)"; exit 1; }
        "$PIXI" run python "$@"
    else
        uv run python "$@"
    fi
}

# ─── Select backend via backend_select.py ────────────────────────────────────

OVERRIDE_FLAG=""
[ -n "${WHISPER_BACKEND:-}" ] && OVERRIDE_FLAG="--override $WHISPER_BACKEND"

# shellcheck disable=SC2086
BACKEND="$(run_python "$SCRIPT_DIR/src/backend_select.py" \
    --system "$OS" $HAS_GPU_FLAG $OVERRIDE_FLAG)"

if [ "$PRINT_ONLY" = "1" ]; then echo "$BACKEND"; exit 0; fi

echo "Platform: $OS | GPU: ${HAS_GPU_FLAG:+yes}${HAS_GPU_FLAG:-no} | Backend: $BACKEND"
export WHISPER_API="${WHISPER_API:-http://localhost:4444/v1/audio/transcriptions}"

# ─── Bring up the backend ─────────────────────────────────────────────────────

case "$BACKEND" in
docker_cuda)
    # shellcheck source=scripts/lib/backend_docker.sh
    source "$SCRIPT_DIR/scripts/lib/backend_docker.sh"
    ensure_docker_backend
    ;;
faster_whisper)
    # shellcheck source=scripts/lib/backend_faster_whisper.sh
    source "$SCRIPT_DIR/scripts/lib/backend_faster_whisper.sh"
    ensure_faster_whisper_backend
    ;;
whispercpp_cpu)
    # shellcheck source=scripts/lib/backend_whispercpp.sh
    source "$SCRIPT_DIR/scripts/lib/backend_whispercpp.sh"
    ensure_whispercpp_backend --cpu
    ;;
whispercpp_metal)
    # shellcheck source=scripts/lib/backend_whispercpp.sh
    source "$SCRIPT_DIR/scripts/lib/backend_whispercpp.sh"
    ensure_whispercpp_backend
    ;;
mlx)
    # shellcheck source=scripts/lib/backend_mlx.sh
    source "$SCRIPT_DIR/scripts/lib/backend_mlx.sh"
    ensure_mlx_backend
    ;;
mlx_audio)
    # shellcheck source=scripts/lib/backend_mlx_audio.sh
    source "$SCRIPT_DIR/scripts/lib/backend_mlx_audio.sh"
    ensure_mlx_audio_backend
    ;;
*)
    echo "Error: unknown backend '$BACKEND'"; exit 1 ;;
esac

# ─── Launch the daemon ────────────────────────────────────────────────────────

echo ""
echo "Backend ready. Starting tigris-whisper Daemon…"
if [ "$OS" = "Darwin" ]; then
    echo "Hold Ctrl+Option+Space to record; release Ctrl to transcribe and paste."
    echo "If the hotkey does not respond, enable Accessibility for your terminal app."
else
    echo "Hold Ctrl+Alt+Space to record; release Ctrl to transcribe and paste."
fi
echo ""

case "$OS" in
Darwin) exec "$PIXI" run python src/whisper_hotkey_mac_experimental.py ;;
*)      exec uv run src/whisper_hotkey_linux.py ;;
esac
