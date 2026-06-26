#!/usr/bin/env bash
set -euo pipefail

# Unified, catalog-driven model switcher for tigris-whisper.
# Choosing a model also selects the right backend for this host: it writes
# WHISPER_BACKEND plus the backend's model env var into tigris-whisper.env, so
# switching between model families (Whisper / Nemotron / Omnilingual / Cohere) is
# seamless behind the unchanged daemon. See src/model_catalog.py for the mapping.
#
# Usage:
#   ./scripts/change_model.sh                          # interactive picker
#   ./scripts/change_model.sh nemotron-3.5-0.6b        # model key (see model_catalog)
#   ./scripts/change_model.sh fast --restart           # Whisper profile + restart
#   ./scripts/change_model.sh <hf/repo-id>             # raw model id for the default backend

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$REPO_DIR/tigris-whisper.env"
OS="$(uname -s)"

if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    set -a; source "$CONFIG_FILE"; set +a
fi

# Backends implemented on this install. Update as Linux GPU/CPU phases land so the
# picker only offers models that actually run here.
IMPLEMENTED_BACKENDS="mlx,mlx_audio,faster_whisper,docker_cuda,whispercpp_cpu,whispercpp_metal,transformers_cuda,nemo_cuda,crispasr"

# GPU flag, mirroring run.sh detection.
GPU_FLAG=""
if [ "$OS" = "Linux" ] && command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
    GPU_FLAG="--has-nvidia-gpu"
fi

# model_catalog imports only stdlib, so call real python3 directly — this works
# even where the pixi/uv env is unavailable or stubbed (e.g. the install test).
PY="$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)"
[ -n "$PY" ] || { echo "Error: python3 not found on PATH"; exit 1; }
catalog() { "$PY" "$REPO_DIR/src/model_catalog.py" "$@"; }

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
    if [ "$OS" = "Darwin" ]; then
        if [ -f "$REPO_DIR/scripts/control_mac_app.sh" ]; then
            echo "Restarting tigris-whisper app…"
            bash "$REPO_DIR/scripts/control_mac_app.sh" restart
        else
            echo "Restart: open ~/Applications/tigris-whisper.app"
        fi
    else
        pkill -f "_server.py" 2>/dev/null || true
        echo "Restart ./run.sh to use the new model."
    fi
}

# ─── Interactive picker ───────────────────────────────────────────────────────

choose_model() {
    # All display output goes to /dev/tty so $() capture gets only the chosen key.
    local tty=/dev/tty
    [ -r /dev/tty ] || tty=/dev/stderr
    local keys=() line key label license langs i=0 reply
    while IFS=$'\t' read -r key label license langs; do
        keys+=("$key"); i=$((i + 1))
        printf '  %2d. %-34s %-16s %s\n' "$i" "$label" "[$license]" "$langs" >"$tty"
    done < <(catalog labels --system "$OS" $GPU_FLAG --known-backends "$IMPLEMENTED_BACKENDS")
    [ "${#keys[@]}" -gt 0 ] || { echo "No models available for this platform." >"$tty"; return 1; }
    echo "" >"$tty"
    printf "Model choice [1]: " >"$tty"
    if [ -r /dev/tty ]; then read -r reply < /dev/tty || reply=""; else read -r reply || reply=""; fi
    reply="${reply:-1}"
    printf '%s\n' "${keys[$((reply - 1))]}"
}

# ─── Usage ───────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: ./scripts/change_model.sh [model-key|profile|hf-repo-id] [--restart]

Model keys and Whisper profiles available on this host:
$(catalog labels --system "$OS" $GPU_FLAG --known-backends "$IMPLEMENTED_BACKENDS" \
    | awk -F'\t' '{printf "  %-22s %s [%s]\n", $1, $2, $3}')

A raw Hugging Face repo id is also accepted and applied to this host's default backend.

Options:
  --restart      Restart the running daemon after saving
  -h, --help     Show this help

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

# Pick the model key (interactive if no arg given).
if [ -n "$MODEL_ARG" ]; then KEY="$MODEL_ARG"; else KEY="$(choose_model)"; fi

# Resolve key → (backend, env_var, model). Unknown keys are treated as a raw model
# id for this host's default backend (the balanced Whisper placement), preserving
# the "custom HF repo id" escape hatch.
if RESOLVED="$(catalog resolve "$KEY" --system "$OS" $GPU_FLAG 2>/dev/null)"; then
    MODEL="$(printf '%s' "$RESOLVED" | cut -f3)"
    RAW=0
else
    RESOLVED="$(catalog resolve balanced --system "$OS" $GPU_FLAG)"
    MODEL="$KEY"
    RAW=1
fi
BACKEND="$(printf '%s' "$RESOLVED" | cut -f1)"
ENV_VAR="$(printf '%s' "$RESOLVED" | cut -f2)"

OLD_MODEL=""
[ -n "$ENV_VAR" ] && OLD_MODEL="${!ENV_VAR:-}"
write_config_key "WHISPER_BACKEND" "$BACKEND"
[ -n "$ENV_VAR" ] && write_config_key "$ENV_VAR" "$MODEL"
[ "$RAW" = "0" ] && write_config_key "TIGRIS_MODEL_PROFILE" "$KEY"

echo ""
echo "Saved: $CONFIG_FILE"
echo "Backend: $BACKEND"
echo "Previous model: ${OLD_MODEL:-none}"
echo "Selected model: $MODEL"
echo ""
echo "First use downloads the model if not cached."

[ "$RESTART" = "1" ] && restart_daemon || echo "Restart ./run.sh for the new model to take effect."
