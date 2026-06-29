#!/usr/bin/env bash
# Sourceable: ensure_omnilingual_backend
# Launches omnilingual_asr_server.py via uv on :4444 (Linux + NVIDIA GPU, or CPU).
# Serves Meta Omnilingual ASR (fairseq2-based, NOT transformers), selected by
# WHISPER_OMNILINGUAL_MODEL. The heavy omnilingual-asr dep is pulled on demand with
# `uv run --with`, so it never touches the project lockfile. Idempotent.

WHISPER_OMNILINGUAL_PORT="${WHISPER_OMNILINGUAL_PORT:-4444}"
_OL_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
_OL_LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/tigris-whisper"
OMNILINGUAL_SERVER_PID=""

ensure_omnilingual_backend() {
    local wanted_model="${WHISPER_OMNILINGUAL_MODEL:-omniASR_LLM_300M_v2}"
    if curl -sf "http://localhost:${WHISPER_OMNILINGUAL_PORT}" >/dev/null 2>&1; then
        local running_model
        running_model="$(curl -sf "http://localhost:${WHISPER_OMNILINGUAL_PORT}" \
            | python3 -c "import sys,json; print(json.load(sys.stdin).get('model',''))" 2>/dev/null || true)"
        if [ "$running_model" = "$wanted_model" ]; then
            echo "✓ Omnilingual server already responding on :${WHISPER_OMNILINGUAL_PORT} (model: $running_model)"; return 0
        fi
        echo "Model changed ($running_model → $wanted_model); restarting server…"
        pkill -f "omnilingual_asr_server.py" 2>/dev/null || true
        sleep 1
    fi

    mkdir -p "$_OL_LOG_DIR"
    echo "Starting Omnilingual ASR server (model: $wanted_model)…"
    echo "  First run resolves omnilingual-asr/fairseq2 and downloads the model — can take several minutes."
    echo "  VRAM: 300M ~5 GB, 1B ~6 GB, 3B ~10 GB, 7B ~17 GB — pick a size that fits your GPU."
    WHISPER_OMNILINGUAL_MODEL="$wanted_model" WHISPER_OMNILINGUAL_PORT="$WHISPER_OMNILINGUAL_PORT" \
        uv run --with omnilingual-asr \
        python -u "$_OL_SCRIPT_DIR/src/omnilingual_asr_server.py" \
        >"$_OL_LOG_DIR/omnilingual_asr_server.log" 2>&1 &
    OMNILINGUAL_SERVER_PID=$!
    trap '[ -n "$OMNILINGUAL_SERVER_PID" ] && kill "$OMNILINGUAL_SERVER_PID" 2>/dev/null' EXIT

    echo "Waiting for Omnilingual API to be ready…"
    local tries=0
    until curl -sf "http://localhost:${WHISPER_OMNILINGUAL_PORT}" >/dev/null 2>&1; do
        if ! kill -0 "$OMNILINGUAL_SERVER_PID" 2>/dev/null; then
            echo "Error: Omnilingual server exited; see $_OL_LOG_DIR/omnilingual_asr_server.log"; return 1
        fi
        tries=$((tries + 1))
        if [ "$tries" -ge 600 ]; then     # generous: dep resolution + model download
            echo "Error: Omnilingual API not ready after 600s; see $_OL_LOG_DIR/omnilingual_asr_server.log"; return 1
        fi
        sleep 1
    done
    echo "✓ Omnilingual server ready on :${WHISPER_OMNILINGUAL_PORT} (PID $OMNILINGUAL_SERVER_PID)"
}
