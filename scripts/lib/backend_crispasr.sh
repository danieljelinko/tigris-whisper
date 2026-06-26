#!/usr/bin/env bash
# Sourceable: ensure_crispasr_backend
# Launches the native CrispASR server on :4444 with the OpenAI-shape endpoint the
# daemon expects. CrispASR is a whisper.cpp-style ggml runtime that serves Cohere
# Transcribe (GGUF) on CPU. Idempotent: if :4444 already answers, reuse it.
# Requires the crispasr binary (run ./scripts/install_crispasr.sh once).

CRISPASR_DIR="${CRISPASR_DIR:-$HOME/.cache/crispasr}"
CRISPASR_PORT="${WHISPER_CRISPASR_PORT:-4444}"
CRISPASR_BACKEND="${CRISPASR_BACKEND:-cohere}"          # which CrispASR model family to serve
# Binary: prefer PATH, fall back to the install_crispasr.sh location.
_crispasr_default_bin="$CRISPASR_DIR/bin/crispasr"
command -v crispasr >/dev/null 2>&1 && _crispasr_default_bin="$(command -v crispasr)"
CRISPASR_BIN="${CRISPASR_BIN:-$_crispasr_default_bin}"
CRISPASR_PID=""

ensure_crispasr_backend() {
    if curl -sf "http://localhost:${CRISPASR_PORT}" >/dev/null 2>&1; then
        echo "✓ CrispASR server already responding on :${CRISPASR_PORT}"; return 0
    fi

    if [ ! -x "$CRISPASR_BIN" ]; then
        echo "Error: CrispASR is not installed."
        echo "  expected binary: $CRISPASR_BIN"
        echo "  run: ./scripts/install_crispasr.sh"
        return 1
    fi

    # WHISPER_CRISPASR_MODEL may be a local .gguf path or an HF repo id. A real
    # file is passed through; anything else (repo id / 'auto') lets CrispASR fetch
    # the backend's default GGUF (cached under ~/.cache/crispasr).
    local model_arg="${WHISPER_CRISPASR_MODEL:-auto}" m="auto"
    [ -f "$model_arg" ] && m="$model_arg"

    mkdir -p "$CRISPASR_DIR"
    echo "Starting CrispASR server (backend: $CRISPASR_BACKEND, model: $m)…"
    echo "  First run downloads the Cohere GGUF (~2.5 GB) to ~/.cache/crispasr."
    "$CRISPASR_BIN" --server --backend "$CRISPASR_BACKEND" -m "$m" \
        --host 127.0.0.1 --port "$CRISPASR_PORT" >"$CRISPASR_DIR/server.log" 2>&1 &
    CRISPASR_PID=$!
    trap '[ -n "$CRISPASR_PID" ] && kill "$CRISPASR_PID" 2>/dev/null' EXIT

    echo "Waiting for CrispASR API to be ready…"
    local tries=0
    until curl -sf "http://localhost:${CRISPASR_PORT}" >/dev/null 2>&1; do
        if ! kill -0 "$CRISPASR_PID" 2>/dev/null; then
            echo "Error: CrispASR server exited; see $CRISPASR_DIR/server.log"; return 1
        fi
        tries=$((tries + 1))
        if [ "$tries" -ge 600 ]; then     # generous: first-run GGUF download on CPU
            echo "Error: CrispASR API not ready after 600s; see $CRISPASR_DIR/server.log"; return 1
        fi
        sleep 1
    done
    echo "✓ CrispASR server ready on :${CRISPASR_PORT} (PID $CRISPASR_PID)"
}
