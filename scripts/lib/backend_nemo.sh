#!/usr/bin/env bash
# Sourceable: ensure_nemo_backend
# Launches nemo_asr_server.py via uv on :4444 (Linux + NVIDIA GPU).
# Serves NVIDIA Nemotron 3.5 ASR, selected by WHISPER_NEMO_MODEL. The heavy
# nemo_toolkit[asr] dep is pulled on demand with `uv run --with`, so it never
# touches the project lockfile. Idempotent: reuse a running server.

WHISPER_NEMO_PORT="${WHISPER_NEMO_PORT:-4444}"
_NM_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
_NM_LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/tigris-whisper"
NEMO_SERVER_PID=""

ensure_nemo_backend() {
    local wanted_model="${WHISPER_NEMO_MODEL:-nvidia/nemotron-3.5-asr-streaming-0.6b}"
    if curl -sf "http://localhost:${WHISPER_NEMO_PORT}" >/dev/null 2>&1; then
        local running_model
        running_model="$(curl -sf "http://localhost:${WHISPER_NEMO_PORT}" \
            | python3 -c "import sys,json; print(json.load(sys.stdin).get('model',''))" 2>/dev/null || true)"
        if [ "$running_model" = "$wanted_model" ]; then
            echo "✓ NeMo server already responding on :${WHISPER_NEMO_PORT} (model: $running_model)"; return 0
        fi
        echo "Model changed ($running_model → $wanted_model); restarting server…"
        pkill -f "nemo_asr_server.py" 2>/dev/null || true
        sleep 1
    fi

    mkdir -p "$_NM_LOG_DIR"
    echo "Starting NeMo ASR server (model: $wanted_model)…"
    echo "  First run resolves nemo_toolkit[asr] and downloads the model — can take several minutes."
    WHISPER_NEMO_MODEL="$wanted_model" WHISPER_NEMO_PORT="$WHISPER_NEMO_PORT" \
        uv run --with "nemo_toolkit[asr]" \
        python -u "$_NM_SCRIPT_DIR/src/nemo_asr_server.py" \
        >"$_NM_LOG_DIR/nemo_asr_server.log" 2>&1 &
    NEMO_SERVER_PID=$!
    trap '[ -n "$NEMO_SERVER_PID" ] && kill "$NEMO_SERVER_PID" 2>/dev/null' EXIT

    echo "Waiting for NeMo API to be ready…"
    local tries=0
    until curl -sf "http://localhost:${WHISPER_NEMO_PORT}" >/dev/null 2>&1; do
        if ! kill -0 "$NEMO_SERVER_PID" 2>/dev/null; then
            echo "Error: NeMo server exited; see $_NM_LOG_DIR/nemo_asr_server.log"; return 1
        fi
        tries=$((tries + 1))
        if [ "$tries" -ge 600 ]; then     # generous: dep resolution + model download
            echo "Error: NeMo API not ready after 600s; see $_NM_LOG_DIR/nemo_asr_server.log"; return 1
        fi
        sleep 1
    done
    echo "✓ NeMo server ready on :${WHISPER_NEMO_PORT} (PID $NEMO_SERVER_PID)"
}
