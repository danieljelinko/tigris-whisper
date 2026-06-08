#!/usr/bin/env bash
# Sourceable: ensure_faster_whisper_backend
# Launches faster_whisper_server.py via uv on :4444. Idempotent: if :4444
# already answers, reuse it.

FASTER_WHISPER_PORT="${FASTER_WHISPER_PORT:-4444}"
_FW_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
_FW_LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/tigris-whisper"
FASTER_WHISPER_SERVER_PID=""

ensure_faster_whisper_backend() {
    local wanted_model="${FASTER_WHISPER_MODEL:-small}"
    if curl -sf "http://localhost:${FASTER_WHISPER_PORT}" >/dev/null 2>&1; then
        local running_model
        running_model="$(curl -sf "http://localhost:${FASTER_WHISPER_PORT}" \
            | python3 -c "import sys,json; print(json.load(sys.stdin).get('model',''))" 2>/dev/null || true)"
        if [ "$running_model" = "$wanted_model" ]; then
            echo "✓ faster-whisper server already responding on :${FASTER_WHISPER_PORT} (model: $running_model)"; return 0
        fi
        echo "Model changed ($running_model → $wanted_model); restarting server…"
        pkill -f "faster_whisper_server.py" 2>/dev/null || true
        sleep 1
    fi

    local model="${FASTER_WHISPER_MODEL:-small}"
    mkdir -p "$_FW_LOG_DIR"

    # Pre-download the model so the server doesn't stall on first load.
    if [ -f "$_FW_SCRIPT_DIR/scripts/download_faster_whisper_model.py" ]; then
        FASTER_WHISPER_MODEL="$model" \
            uv run python "$_FW_SCRIPT_DIR/scripts/download_faster_whisper_model.py" || true
    fi

    echo "Starting faster-whisper server (model: $model)…"
    FASTER_WHISPER_MODEL="$model" \
        uv run python -u "$_FW_SCRIPT_DIR/src/faster_whisper_server.py" \
        >"$_FW_LOG_DIR/faster_whisper_server.log" 2>&1 &
    FASTER_WHISPER_SERVER_PID=$!
    trap '[ -n "$FASTER_WHISPER_SERVER_PID" ] && kill "$FASTER_WHISPER_SERVER_PID" 2>/dev/null' EXIT

    echo "Waiting for faster-whisper API to be ready…"
    local tries=0
    until curl -sf "http://localhost:${FASTER_WHISPER_PORT}" >/dev/null 2>&1; do
        if ! kill -0 "$FASTER_WHISPER_SERVER_PID" 2>/dev/null; then
            echo "Error: faster-whisper server exited unexpectedly."
            echo "  Log: $_FW_LOG_DIR/faster_whisper_server.log"
            return 1
        fi
        tries=$((tries + 1))
        if [ "$tries" -ge 120 ]; then
            echo "Error: faster-whisper API not ready after 120s."
            echo "  Log: $_FW_LOG_DIR/faster_whisper_server.log"
            return 1
        fi
        sleep 1
    done
    echo "✓ faster-whisper server ready on :${FASTER_WHISPER_PORT} (PID $FASTER_WHISPER_SERVER_PID)"
}
