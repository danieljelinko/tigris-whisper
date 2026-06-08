#!/usr/bin/env bash
set -euo pipefail

# Unified model switcher for tigris-whisper.
# Detects the active backend and shows the appropriate model options.
# Delegates to backend-specific logic but presents a single entry point.
#
# Usage:
#   ./scripts/change_model.sh                    # interactive picker
#   ./scripts/change_model.sh fast               # profile shorthand
#   ./scripts/change_model.sh fast --restart     # switch and restart daemon

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$REPO_DIR/tigris-whisper.env"
OS="$(uname -s)"

if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    set -a; source "$CONFIG_FILE"; set +a
fi

# ─── Backend detection (mirrors backend_select.py logic) ─────────────────────

detect_backend() {
    [ -n "${WHISPER_BACKEND:-}" ] && { echo "$WHISPER_BACKEND"; return; }
    if [ "$OS" = "Darwin" ]; then echo "mlx"; return; fi
    if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
        echo "docker_cuda"; return
    fi
    echo "faster_whisper"
}

BACKEND="$(detect_backend)"

# ─── Profile → model ID tables ───────────────────────────────────────────────

mlx_model_for_profile() {
    case "$1" in
        balanced|1)      echo "mlx-community/whisper-large-v3-turbo-q4" ;;
        fast|2)          echo "mlx-community/whisper-small-mlx-q4" ;;
        very-fast|3)     echo "mlx-community/whisper-base-mlx-q4" ;;
        best-accuracy|4) echo "mlx-community/whisper-large-v3-turbo" ;;
        *)               echo "$1" ;;
    esac
}

fw_model_for_profile() {
    case "$1" in
        balanced|1)      echo "small" ;;
        fast|2)          echo "base" ;;
        very-fast|3)     echo "tiny" ;;
        best-accuracy|4) echo "large-v3-turbo" ;;
        *)               echo "$1" ;;
    esac
}

mlx_profile_for_model() {
    case "$1" in
        mlx-community/whisper-large-v3-turbo-q4) echo "balanced" ;;
        mlx-community/whisper-small-mlx-q4)      echo "fast" ;;
        mlx-community/whisper-base-mlx-q4)        echo "very-fast" ;;
        mlx-community/whisper-large-v3-turbo)     echo "best-accuracy" ;;
        *) echo "custom" ;;
    esac
}

fw_profile_for_model() {
    case "$1" in
        small)          echo "balanced" ;;
        base)           echo "fast" ;;
        tiny)           echo "very-fast" ;;
        large-v3-turbo) echo "best-accuracy" ;;
        *) echo "custom" ;;
    esac
}

# ─── Interactive picker ───────────────────────────────────────────────────────

choose_mlx() {
    # All display output goes to /dev/tty so $() capture gets only the model id.
    local reply="" tty=/dev/tty
    [ -r /dev/tty ] || tty=/dev/stderr
    echo "Choose model (macOS / mlx-whisper):" >"$tty"
    echo "  All choices are multilingual Whisper models." >"$tty"
    echo "" >"$tty"
    echo "  1. Balanced (default): large-v3-turbo-q4  — good accuracy, quantized" >"$tty"
    echo "  2. Fast:               small-mlx-q4        — lower latency" >"$tty"
    echo "  3. Very fast:          base-mlx-q4         — fastest, less accurate" >"$tty"
    echo "  4. Best accuracy:      large-v3-turbo      — larger download/RAM" >"$tty"
    printf "Model choice [1]: " >"$tty"
    if [ -r /dev/tty ]; then read -r reply < /dev/tty || reply=""; else read -r reply || reply=""; fi
    mlx_model_for_profile "${reply:-1}"
}

choose_faster_whisper() {
    # All display output goes to /dev/tty so $() capture gets only the model id.
    local reply="" tty=/dev/tty
    [ -r /dev/tty ] || tty=/dev/stderr
    echo "Choose model (Linux / faster-whisper CPU):" >"$tty"
    echo "  All choices are multilingual Whisper models." >"$tty"
    echo "" >"$tty"
    echo "  1. Balanced (default): small          — ~490 MB, good accuracy" >"$tty"
    echo "  2. Fast:               base            — ~145 MB, lower latency" >"$tty"
    echo "  3. Very fast:          tiny            — ~75 MB, fastest" >"$tty"
    echo "  4. Best accuracy:      large-v3-turbo  — ~1.6 GB, slower on CPU" >"$tty"
    printf "Model choice [1]: " >"$tty"
    if [ -r /dev/tty ]; then read -r reply < /dev/tty || reply=""; else read -r reply || reply=""; fi
    fw_model_for_profile "${reply:-1}"
}

# ─── Config writer ────────────────────────────────────────────────────────────

write_config_key() {
    local key="$1" value="$2"
    local tmp
    tmp="$(mktemp)"
    if [ -f "$CONFIG_FILE" ]; then
        grep -v "^export ${key}=" "$CONFIG_FILE" > "$tmp" || true
    fi
    printf 'export %s=%q\n' "$key" "$value" >> "$tmp"
    mv "$tmp" "$CONFIG_FILE"
}

# ─── Restart helper ──────────────────────────────────────────────────────────

restart_daemon() {
    case "$BACKEND" in
        mlx)
            if [ -f "$REPO_DIR/scripts/control_mac_app.sh" ]; then
                echo "Restarting tigris-whisper app…"
                bash "$REPO_DIR/scripts/control_mac_app.sh" restart
            else
                echo "Restart: open ~/Applications/tigris-whisper.app"
            fi
            ;;
        faster_whisper)
            pkill -f "faster_whisper_server.py" 2>/dev/null || true
            echo "Restart ./run.sh to use the new model."
            ;;
        *)
            echo "Restart ./run.sh to use the new model."
            ;;
    esac
}

# ─── Usage ───────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: ./scripts/change_model.sh [profile|model-id] [--restart]

Profiles (work on all backends):
  balanced       Default — good accuracy, reasonable size
  fast           Lower latency, smaller model
  very-fast      Fastest, least accurate
  best-accuracy  Largest, most accurate

Options:
  --restart      Restart the running daemon after saving
  -h, --help     Show this help

Detected backend: $BACKEND
Run with no arguments for an interactive picker.
EOF
}

# ─── Main ─────────────────────────────────────────────────────────────────────

RESTART=0
MODEL_ARG=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --restart) RESTART=1 ;;
        -h|--help) usage; exit 0 ;;
        *)
            if [ -n "$MODEL_ARG" ]; then echo "Error: only one model/profile argument allowed."; usage; exit 1; fi
            MODEL_ARG="$1"
            ;;
    esac
    shift
done

echo "Backend: $BACKEND"

case "$BACKEND" in
mlx)
    OLD_MODEL="${WHISPER_MLX_MODEL:-}"
    if [ -n "$MODEL_ARG" ]; then
        MODEL="$(mlx_model_for_profile "$MODEL_ARG")"
    else
        [ -n "$OLD_MODEL" ] && echo "Current model: $OLD_MODEL"
        MODEL="$(choose_mlx)"
    fi
    PROFILE="$(mlx_profile_for_model "$MODEL")"
    write_config_key "WHISPER_MLX_MODEL" "$MODEL"
    write_config_key "TIGRIS_MODEL_PROFILE" "$PROFILE"
    ;;
faster_whisper)
    OLD_MODEL="${FASTER_WHISPER_MODEL:-}"
    if [ -n "$MODEL_ARG" ]; then
        MODEL="$(fw_model_for_profile "$MODEL_ARG")"
    else
        [ -n "$OLD_MODEL" ] && echo "Current model: $OLD_MODEL"
        MODEL="$(choose_faster_whisper)"
    fi
    PROFILE="$(fw_profile_for_model "$MODEL")"
    write_config_key "FASTER_WHISPER_MODEL" "$MODEL"
    write_config_key "TIGRIS_MODEL_PROFILE" "$PROFILE"
    ;;
docker_cuda)
    echo "The Docker CUDA backend uses a model baked into the container image."
    echo "To change it, rebuild the image with a different model."
    echo "  See: scripts/101_install_whispercpp.sh or the whisper-assistant-vscode repo."
    exit 0
    ;;
*)
    echo "Error: unknown backend '$BACKEND'. Set WHISPER_BACKEND to override detection."
    exit 1
    ;;
esac

echo ""
echo "Saved: $CONFIG_FILE"
echo "Previous model: ${OLD_MODEL:-none}"
echo "Selected model: $MODEL  (profile: $PROFILE)"
echo ""
echo "First use downloads the model if not cached."

[ "$RESTART" = "1" ] && restart_daemon || echo "Restart ./run.sh for the new model to take effect."
