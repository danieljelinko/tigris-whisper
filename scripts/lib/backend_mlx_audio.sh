#!/usr/bin/env bash
# Sourceable: ensure_mlx_audio_backend
# Launches the mlx-audio HTTP wrapper on :4444 (Apple Silicon only).
# Serves Nemotron 3.5 ASR / Meta Omnilingual / Cohere Transcribe from one library,
# selected by WHISPER_MLX_AUDIO_MODEL. The model is pre-downloaded before the
# server starts so foreground terminal runs can show Hugging Face/tqdm progress.

MLXA_PORT="${WHISPER_MLX_AUDIO_PORT:-4444}"
MLXA_HOST="${WHISPER_MLX_AUDIO_HOST:-127.0.0.1}"
MLXA_DIR="${WHISPERCPP_DIR:-$HOME/.cache/whisper.cpp}"   # reuse cache dir for the server log
MLXA_MODEL="${WHISPER_MLX_AUDIO_MODEL:-mlx-community/nemotron-3.5-asr-streaming-0.6b}"
MLXA_PID=""
PIXI="$(command -v pixi 2>/dev/null || printf '%s/.pixi/bin/pixi' "$HOME")"

ensure_mlx_audio_backend() {
    if curl -sf "http://localhost:${MLXA_PORT}" >/dev/null 2>&1; then
        echo "✓ mlx-audio server already responding on :${MLXA_PORT}"; return 0
    fi

    mkdir -p "$MLXA_DIR"
    echo "Checking mlx-audio model cache…"
    echo "  Model: ${MLXA_MODEL}"
    echo "  First run downloads from Hugging Face and can take several minutes."
    echo "  Progress bars appear below when files are downloading."
    HF_HUB_DISABLE_XET="${HF_HUB_DISABLE_XET:-1}" \
        "$PIXI" run python -c "import sys; from mlx_audio.stt import load; load(sys.argv[1])" "$MLXA_MODEL"

    echo "Starting mlx-audio server…"
    HF_HUB_DISABLE_XET="${HF_HUB_DISABLE_XET:-1}" \
        WHISPER_MLX_AUDIO_MODEL="$MLXA_MODEL" \
        WHISPER_MLX_AUDIO_HOST="$MLXA_HOST" WHISPER_MLX_AUDIO_PORT="$MLXA_PORT" \
        "$PIXI" run python "$SCRIPT_DIR/src/mlx_audio_server.py" >"$MLXA_DIR/mlx_audio_server.log" 2>&1 &
    MLXA_PID=$!
    trap '[ -n "$MLXA_PID" ] && kill "$MLXA_PID" 2>/dev/null' EXIT

    echo "Waiting for mlx-audio API to be ready…"
    local tries=0
    until curl -sf "http://localhost:${MLXA_PORT}" >/dev/null 2>&1; do
        if ! kill -0 "$MLXA_PID" 2>/dev/null; then
            echo "Error: mlx-audio server exited; see $MLXA_DIR/mlx_audio_server.log"; return 1
        fi
        tries=$((tries + 1))
        if [ "$tries" -ge 300 ]; then     # generous: first-run model download
            echo "Error: mlx-audio API not ready after 300s; see $MLXA_DIR/mlx_audio_server.log"; return 1
        fi
        sleep 1
    done
    echo "✓ mlx-audio server ready on :${MLXA_PORT} (PID $MLXA_PID)"
}
