#!/usr/bin/env bash
# Sourceable: ensure_transformers_backend
# Launches transformers_asr_server.py via uv on :4444 (Linux + NVIDIA GPU).
# Serves Cohere Transcribe / Meta Omnilingual, selected by WHISPER_TRANSFORMERS_MODEL.
# The heavy deps (transformers/torch) are pulled on demand with `uv run --with`,
# so they never touch the project lockfile. Idempotent: reuse a running server.

WHISPER_TRANSFORMERS_PORT="${WHISPER_TRANSFORMERS_PORT:-4444}"
_TF_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
_TF_LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/tigris-whisper"
TRANSFORMERS_SERVER_PID=""

ensure_transformers_backend() {
    local wanted_model="${WHISPER_TRANSFORMERS_MODEL:-CohereLabs/cohere-transcribe-03-2026}"
    if curl -sf "http://localhost:${WHISPER_TRANSFORMERS_PORT}" >/dev/null 2>&1; then
        local running_model
        running_model="$(curl -sf "http://localhost:${WHISPER_TRANSFORMERS_PORT}" \
            | python3 -c "import sys,json; print(json.load(sys.stdin).get('model',''))" 2>/dev/null || true)"
        if [ "$running_model" = "$wanted_model" ]; then
            echo "✓ transformers server already responding on :${WHISPER_TRANSFORMERS_PORT} (model: $running_model)"; return 0
        fi
        echo "Model changed ($running_model → $wanted_model); restarting server…"
        pkill -f "transformers_asr_server.py" 2>/dev/null || true
        sleep 1
    fi

    mkdir -p "$_TF_LOG_DIR"
    echo "Starting transformers ASR server (model: $wanted_model)…"
    echo "  First run resolves transformers/torch and downloads the model — can take several minutes."
    WHISPER_TRANSFORMERS_MODEL="$wanted_model" \
        WHISPER_TRANSFORMERS_DEVICE="${WHISPER_TRANSFORMERS_DEVICE:-cuda}" \
        WHISPER_TRANSFORMERS_PORT="$WHISPER_TRANSFORMERS_PORT" \
        uv run --with transformers --with torch --with soundfile --with librosa --with accelerate \
        python -u "$_TF_SCRIPT_DIR/src/transformers_asr_server.py" \
        >"$_TF_LOG_DIR/transformers_asr_server.log" 2>&1 &
    TRANSFORMERS_SERVER_PID=$!
    trap '[ -n "$TRANSFORMERS_SERVER_PID" ] && kill "$TRANSFORMERS_SERVER_PID" 2>/dev/null' EXIT

    echo "Waiting for transformers API to be ready…"
    local tries=0
    until curl -sf "http://localhost:${WHISPER_TRANSFORMERS_PORT}" >/dev/null 2>&1; do
        if ! kill -0 "$TRANSFORMERS_SERVER_PID" 2>/dev/null; then
            echo "Error: transformers server exited; see $_TF_LOG_DIR/transformers_asr_server.log"; return 1
        fi
        tries=$((tries + 1))
        if [ "$tries" -ge 600 ]; then     # generous: dep resolution + multi-GB model download
            echo "Error: transformers API not ready after 600s; see $_TF_LOG_DIR/transformers_asr_server.log"; return 1
        fi
        sleep 1
    done
    echo "✓ transformers server ready on :${WHISPER_TRANSFORMERS_PORT} (PID $TRANSFORMERS_SERVER_PID)"
}
